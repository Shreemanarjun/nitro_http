// nitro_completion_batch.h — shared-port completion batching for
// @nitroNativeAsync results.
//
// Every message posted to a Dart isolate costs one event-loop task on the
// embedder's message loop (~10 µs in Flutter), whichever port it targets. This
// batcher lets N completions that arrive while the isolate is still busy with
// the previous one travel as ONE message.
//
// Protocol (per library):
//   Dart: id = <lib>_nitro_bind(batchPort)      — before the native call;
//         the call receives `id` where it used to receive a Dart port.
//   Native: Dart_PostCObject_DL(id, obj)        — every existing post site,
//         redirected here by the macro in the generated bridge header.
//   Dart: <lib>_nitro_ack(batchPort)            — after handling a batch.
//
// Delivery: the batch port receives a kArray [id0, obj0, id1, obj1, ...]. At
// most one message is in flight per batch port; completions that arrive
// before the ack are copied and sent together on the ack. Ports that were
// never bound (entry points, hand-written posts to real ports) go straight
// to Dart_PostCObject_DL, unchanged.
//
// Streams: a @NitroStream(backpressure: batch) port on an all-C++ spec is
// registered with coalesce(port) — the port is its own batch target for as
// long as it is subscribed. Its items travel as a kArray [obj, obj, ...]
// (always wrapped, even a lone one) and Dart acks the port after each
// message, so a burst costs one wake per Dart turn instead of one per item.
#ifndef NITRO_COMPLETION_BATCH_H_
#define NITRO_COMPLETION_BATCH_H_

#include <stdint.h>
#include <string.h>

// C++ only: the SwiftPM include directory is also scanned as a C module, so
// the std headers and the class stay behind __cplusplus (C callers only need
// the exported <lib>_nitro_post/bind/ack declared in the bridge header).
#ifdef __cplusplus
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "dart_api_dl.h"

class NitroCompletionBatch {
 public:
  // A deep copy of a Dart_CObject that owns its storage.
  struct Owned {
    Dart_CObject obj{};
    std::vector<char> bytes;                         // kString / kTypedData payload
    std::vector<std::unique_ptr<Owned>> children;    // kArray elements
    std::vector<Dart_CObject*> childPtrs;

    static std::unique_ptr<Owned> copy(const Dart_CObject* src) {
      auto o = std::unique_ptr<Owned>(new Owned());
      o->obj = *src;
      switch (src->type) {
        case Dart_CObject_kString: {
          const char* s = src->value.as_string ? src->value.as_string : "";
          o->bytes.assign(s, s + strlen(s) + 1);
          o->obj.value.as_string = o->bytes.data();
          break;
        }
        case Dart_CObject_kTypedData: {
          const size_t n = (size_t)src->value.as_typed_data.length * elemSize(src->value.as_typed_data.type);
          o->bytes.assign((const char*)src->value.as_typed_data.values, (const char*)src->value.as_typed_data.values + n);
          o->obj.value.as_typed_data.values = (const uint8_t*)o->bytes.data();
          break;
        }
        case Dart_CObject_kExternalTypedData:
        case Dart_CObject_kUnmodifiableExternalTypedData: {
          // Copy the payload and release the native buffer now, exactly as the
          // VM would after copying on post.
          const auto& e = src->value.as_external_typed_data;
          const size_t n = (size_t)e.length * elemSize(e.type);
          o->bytes.assign((const char*)e.data, (const char*)e.data + n);
          o->obj.type = Dart_CObject_kTypedData;
          o->obj.value.as_typed_data.type = e.type;
          o->obj.value.as_typed_data.length = e.length;
          o->obj.value.as_typed_data.values = (const uint8_t*)o->bytes.data();
          if (e.callback) e.callback(nullptr, e.peer);
          break;
        }
        case Dart_CObject_kArray: {
          const intptr_t n = src->value.as_array.length;
          for (intptr_t i = 0; i < n; i++) o->children.push_back(copy(src->value.as_array.values[i]));
          for (auto& c : o->children) o->childPtrs.push_back(&c->obj);
          o->obj.value.as_array.values = o->childPtrs.data();
          break;
        }
        default:
          break;  // scalars copied by value
      }
      return o;
    }

    static size_t elemSize(Dart_TypedData_Type t) {
      switch (t) {
        case Dart_TypedData_kInt16: case Dart_TypedData_kUint16: return 2;
        case Dart_TypedData_kInt32: case Dart_TypedData_kUint32: case Dart_TypedData_kFloat32: return 4;
        case Dart_TypedData_kInt64: case Dart_TypedData_kUint64: case Dart_TypedData_kFloat64: return 8;
        default: return 1;
      }
    }
  };

  // Dart side, before a call: reserve an id routed to [batchPort].
  int64_t bind(int64_t batchPort) {
    std::lock_guard<std::mutex> lk(mu_);
    const int64_t id = ++seq_;
    bound_[id] = batchPort;
    return id;
  }

  // Stream register/release: the port coalesces its own items until released.
  // [freeItem] releases one heap item (kInt64 address) the way Dart would
  // have — struct/record/variant streams pass it so items that are never
  // delivered (released mid-burst, or a flush to a closed port) are freed.
  using FreeItem = void (*)(int64_t);
  void coalesce(int64_t port, FreeItem freeItem = nullptr) {
    std::lock_guard<std::mutex> lk(mu_);
    coalesced_[port] = freeItem;
  }
  void uncoalesce(int64_t port) {
    std::vector<std::pair<int64_t, std::unique_ptr<Owned>>> dropped;
    FreeItem freeItem = nullptr;
    {
      std::lock_guard<std::mutex> lk(mu_);
      auto c = coalesced_.find(port);
      if (c != coalesced_.end()) freeItem = c->second;
      coalesced_.erase(port);
      auto it = ports_.find(port);
      if (it != ports_.end()) {
        dropped.swap(it->second.pending);
        ports_.erase(it);
      }
    }
    freeItems(freeItem, dropped);
  }

  // Native side: every post. Unbound ports post directly.
  bool post(int64_t idOrPort, Dart_CObject* obj) {
    int64_t batchPort;
    bool stream = false;
    {
      std::lock_guard<std::mutex> lk(mu_);
      auto it = bound_.find(idOrPort);
      if (it != bound_.end()) {
        batchPort = it->second;
        bound_.erase(it);
      } else if (coalesced_.count(idOrPort) != 0) {
        batchPort = idOrPort;
        stream = true;
      } else {
        return (Dart_PostCObject_DL)(idOrPort, obj);
      }
      State& st = ports_[batchPort];
      if (st.inFlight && copyable(obj)) {
        st.pending.emplace_back(idOrPort, Owned::copy(obj));
        return true;
      }
      st.inFlight = true;
    }
    return stream ? postItems(batchPort, {obj}) : postPairs(batchPort, {{idOrPort, obj}});
  }

  // Dart side, after handling a batch: flush what accumulated, or go idle.
  void ack(int64_t batchPort) {
    std::vector<std::pair<int64_t, std::unique_ptr<Owned>>> pending;
    bool stream;
    FreeItem freeItem = nullptr;
    {
      std::lock_guard<std::mutex> lk(mu_);
      auto it = ports_.find(batchPort);
      if (it == ports_.end()) return;
      if (it->second.pending.empty()) {
        it->second.inFlight = false;
        return;
      }
      pending.swap(it->second.pending);
      auto c = coalesced_.find(batchPort);
      stream = c != coalesced_.end();
      if (stream) freeItem = c->second;
    }
    if (stream) {
      std::vector<Dart_CObject*> items;
      items.reserve(pending.size());
      for (auto& p : pending) items.push_back(&p.second->obj);
      // A port closed between the post and this flush never takes ownership.
      if (!postItems(batchPort, items)) freeItems(freeItem, pending);
      return;
    }
    std::vector<std::pair<int64_t, Dart_CObject*>> pairs;
    pairs.reserve(pending.size());
    for (auto& p : pending) pairs.emplace_back(p.first, &p.second->obj);
    postPairs(batchPort, pairs);
  }

 private:
  struct State {
    bool inFlight = false;
    std::vector<std::pair<int64_t, std::unique_ptr<Owned>>> pending;
  };

  static bool copyable(const Dart_CObject* obj) {
    switch (obj->type) {
      case Dart_CObject_kNull: case Dart_CObject_kBool: case Dart_CObject_kInt32: case Dart_CObject_kInt64:
      case Dart_CObject_kDouble: case Dart_CObject_kString: case Dart_CObject_kTypedData:
      case Dart_CObject_kExternalTypedData: case Dart_CObject_kUnmodifiableExternalTypedData:
        return true;
      case Dart_CObject_kArray:
        for (intptr_t i = 0; i < obj->value.as_array.length; i++) {
          if (!copyable(obj->value.as_array.values[i])) return false;
        }
        return true;
      default:
        return false;  // send ports, capabilities, native pointers: post now
    }
  }

  // [id0, obj0, id1, obj1, ...] as one kArray message.
  static bool postPairs(int64_t batchPort, const std::vector<std::pair<int64_t, Dart_CObject*>>& pairs) {
    std::vector<Dart_CObject> ids(pairs.size());
    std::vector<Dart_CObject*> values(pairs.size() * 2);
    for (size_t i = 0; i < pairs.size(); i++) {
      ids[i].type = Dart_CObject_kInt64;
      ids[i].value.as_int64 = pairs[i].first;
      values[2 * i] = &ids[i];
      values[2 * i + 1] = pairs[i].second;
    }
    Dart_CObject batch;
    batch.type = Dart_CObject_kArray;
    batch.value.as_array.length = (intptr_t)values.size();
    batch.value.as_array.values = values.data();
    return (Dart_PostCObject_DL)(batchPort, &batch);
  }

  static void freeItems(FreeItem freeItem, const std::vector<std::pair<int64_t, std::unique_ptr<Owned>>>& items) {
    if (!freeItem) return;
    for (const auto& p : items) {
      if (p.second->obj.type == Dart_CObject_kInt64 && p.second->obj.value.as_int64 != 0) freeItem(p.second->obj.value.as_int64);
    }
  }

  // Stream items: [obj, obj, ...] as one kArray message.
  static bool postItems(int64_t port, const std::vector<Dart_CObject*>& items) {
    Dart_CObject batch;
    batch.type = Dart_CObject_kArray;
    batch.value.as_array.length = (intptr_t)items.size();
    batch.value.as_array.values = const_cast<Dart_CObject**>(items.data());
    return (Dart_PostCObject_DL)(port, &batch);
  }

  std::mutex mu_;
  int64_t seq_ = 0;
  std::unordered_map<int64_t, int64_t> bound_;  // id → batch port
  std::unordered_map<int64_t, FreeItem> coalesced_;  // stream port → item free (own batch target)
  std::unordered_map<int64_t, State> ports_;    // batch port → in-flight state
};

#endif  // __cplusplus
#endif  // NITRO_COMPLETION_BATCH_H_
