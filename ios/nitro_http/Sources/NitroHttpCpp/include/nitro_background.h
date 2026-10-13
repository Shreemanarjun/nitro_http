// nitro_background.h — process-wide job table behind @NitroEntryPoint.
//
// One NitroBgTable per generated library. Flow:
//   Dart (any isolate)  submit(entry, args, dartPort) → jobId, then either the
//                       registered host starter launches a headless engine at
//                       the entry wrapper, or Dart spawns a fallback isolate.
//   Background isolate  take(entry) → the oldest pending job for that entry.
//                       complete(id, result) / fail(id, error) post to the
//                       submitting isolate's port and notify the host (done).
// Header-only, C++11, no Dart headers beyond dart_api_dl.h (included by the
// bridge before this file). Thread-safe: every call may come from any thread.
#pragma once
// SwiftPM scans every header under include/ as a C module — this file is C++
// only, so the scan must see an empty header (same reason nitro_wasm_compat.h
// is kept out of include/).
#ifdef __cplusplus
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

struct NitroBgJob {
  int64_t id;
  std::string entry;
  std::string args;  // record-wire blob (binary-safe)
  int64_t dartPort;
};

class NitroBgTable {
 public:
  // Host hooks. starter runs an engine at the wrapper for `entry` and returns
  // nonzero on success; done is told when a job finished so the engine can go.
  typedef int (*Starter)(const char* entry, int64_t jobId, void* ctx);
  // `error` is null when the job completed (or was cancelled), else the
  // thrown error's text — the host forwards it to native completion callbacks.
  typedef void (*Done)(int64_t jobId, const char* error, void* ctx);

  void registerHost(Starter starter, Done done, void* ctx) {
    std::lock_guard<std::mutex> lk(mutex_);
    starter_ = starter;
    done_ = done;
    ctx_ = ctx;
  }

  bool hasHost() {
    std::lock_guard<std::mutex> lk(mutex_);
    return starter_ != nullptr;
  }

  // Enqueues the job; if a host is registered its starter is invoked (outside
  // the lock). Returns the job id; hostStarted reports whether a host took it
  // (false → caller must run the wrapper itself, e.g. on a spawned isolate).
  int64_t submit(const char* entry, const uint8_t* args, size_t argsLen, int64_t dartPort, bool* hostStarted) {
    Starter starter;
    void* ctx;
    int64_t id;
    {
      std::lock_guard<std::mutex> lk(mutex_);
      id = next_++;
      pending_.push_back(NitroBgJob{id, entry ? entry : "", std::string(reinterpret_cast<const char*>(args ? args : reinterpret_cast<const uint8_t*>("")), args ? argsLen : 0), dartPort});
      starter = starter_;
      ctx = ctx_;
    }
    bool started = false;
    if (starter) started = starter(entry, id, ctx) != 0;
    if (hostStarted) *hostStarted = started;
    return id;
  }

  // The background isolate claims the oldest pending job for its entry.
  // Moves one pending job of `entry` to in-flight and hands its args to the
  // runner. `id` binds the runner to the job it was started for (the host
  // keys its engine by that id, so a later completion tears down the right
  // engine); `id == 0` takes the oldest pending job of the entry instead —
  // the path for hosts that cannot pass entrypoint arguments.
  bool take(const char* entry, int64_t id, int64_t* outId, std::string* outArgs) {
    std::lock_guard<std::mutex> lk(mutex_);
    for (std::deque<NitroBgJob>::iterator it = pending_.begin(); it != pending_.end(); ++it) {
      if (it->entry == (entry ? entry : "") && (id == 0 || it->id == id)) {
        *outId = it->id;
        *outArgs = it->args;
        inflight_[it->id] = *it;
        pending_.erase(it);
        return true;
      }
    }
    return false;
  }

  // Native-initiated job (no Dart submitter, e.g. a WorkManager worker):
  // enqueued with port 0 so results are dropped; returns -1 when no host is
  // registered (nothing could start the engine).
  // Jobs submitted but not yet finished (pending + in-flight).
  int64_t activeCount() {
    std::lock_guard<std::mutex> lk(mutex_);
    return static_cast<int64_t>(pending_.size() + inflight_.size());
  }
  int64_t runNative(const char* entry, const uint8_t* args, size_t argsLen) {
    if (!hasHost()) return -1;
    bool started = false;
    int64_t id = submit(entry, args, argsLen, 0, &started);
    if (!started) { cancel(id); return -1; }
    return id;
  }

  // Success: posts the result blob (record wire format) to the submitter as
  // Uint8 typed data. Returns false for an unknown id.
  bool complete(int64_t id, const uint8_t* result, size_t len) {
    NitroBgJob job;
    if (!pop(id, &job)) return false;
    postBlob(job.dartPort, result, len);
    notifyDone(id, nullptr);
    return true;
  }

  // Stream item: posts one blob and keeps the job in flight. False once the
  // submitter cancelled (the producer should stop).
  bool emit(int64_t id, const uint8_t* data, size_t len) {
    int64_t port;
    {
      std::lock_guard<std::mutex> lk(mutex_);
      std::unordered_map<int64_t, NitroBgJob>::iterator it = inflight_.find(id);
      if (it == inflight_.end()) return false;
      port = it->second.dartPort;
    }
    postBlob(port, data, len);
    return true;
  }

  // Stream end: posts null (the Dart side closes the stream) and finishes.
  bool end(int64_t id) {
    NitroBgJob job;
    if (!pop(id, &job)) return false;
    if (job.dartPort != 0) {
      Dart_CObject obj;
      obj.type = Dart_CObject_kNull;
      Dart_PostCObject_DL(job.dartPort, &obj);
    }
    notifyDone(id, nullptr);
    return true;
  }

  // Submitter cancelled: forget the job so emit/complete return false and the
  // host can tear the engine down.
  bool cancel(int64_t id) {
    NitroBgJob job;
    if (!pop(id, &job)) return false;
    notifyDone(id, nullptr);
    return true;
  }

  // Failure: posts a one-element array [error] so Dart can tell it from a result.
  // Posts [error, stackTrace, entry] to the submitter (all strings; the
  // Dart side turns it into a NitroBackgroundException) and tells the host.
  bool fail(int64_t id, const char* error, const char* stackTrace) {
    NitroBgJob job;
    if (!pop(id, &job)) return false;
    const char* msg = error ? error : "background job failed";
    if (job.dartPort == 0) { notifyDone(id, msg); return true; }
    Dart_CObject m;
    m.type = Dart_CObject_kString;
    m.value.as_string = const_cast<char*>(msg);
    Dart_CObject st;
    st.type = Dart_CObject_kString;
    st.value.as_string = const_cast<char*>(stackTrace ? stackTrace : "");
    Dart_CObject en;
    en.type = Dart_CObject_kString;
    en.value.as_string = const_cast<char*>(job.entry.c_str());
    Dart_CObject* elems[3] = {&m, &st, &en};
    Dart_CObject arr;
    arr.type = Dart_CObject_kArray;
    arr.value.as_array.length = 3;
    arr.value.as_array.values = elems;
    Dart_PostCObject_DL(job.dartPort, &arr);
    notifyDone(id, msg);
    return true;
  }

  // Posts one blob (copied) to any native port of this process — job results,
  // stream items, and callback-parameter invocations alike.
  static void postBlob(int64_t port, const uint8_t* data, size_t len) {
    if (port == 0) return;
    Dart_CObject obj;
    obj.type = Dart_CObject_kTypedData;
    obj.value.as_typed_data.type = Dart_TypedData_kUint8;
    obj.value.as_typed_data.length = static_cast<intptr_t>(len);
    obj.value.as_typed_data.values = const_cast<uint8_t*>(data ? data : reinterpret_cast<const uint8_t*>(""));
    Dart_PostCObject_DL(port, &obj);
  }

 private:
  bool pop(int64_t id, NitroBgJob* out) {
    std::lock_guard<std::mutex> lk(mutex_);
    std::unordered_map<int64_t, NitroBgJob>::iterator it = inflight_.find(id);
    if (it == inflight_.end()) {
      // Completing a job nobody took (host started an engine that finished
      // without take) — still honour it if it is pending.
      for (std::deque<NitroBgJob>::iterator p = pending_.begin(); p != pending_.end(); ++p) {
        if (p->id == id) { *out = *p; pending_.erase(p); return true; }
      }
      return false;
    }
    *out = it->second;
    inflight_.erase(it);
    return true;
  }

  void notifyDone(int64_t id, const char* error) {
    Done done;
    void* ctx;
    {
      std::lock_guard<std::mutex> lk(mutex_);
      done = done_;
      ctx = ctx_;
    }
    if (done) done(id, error, ctx);
  }

  std::mutex mutex_;
  int64_t next_ = 1;
  std::deque<NitroBgJob> pending_;
  std::unordered_map<int64_t, NitroBgJob> inflight_;
  Starter starter_ = nullptr;
  Done done_ = nullptr;
  void* ctx_ = nullptr;
};
#endif  // __cplusplus
