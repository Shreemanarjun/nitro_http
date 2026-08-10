// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — the native-async completion seam.
//
// One post per accepted request, no exceptions. The blob is accounted for on
// every path out of `postRecord`, because the two failure modes here are a
// permanent leak (never freed) and a hung Dart `Future` (never posted), and both
// are invisible until production.
// ─────────────────────────────────────────────────────────────────────────────

#include "DartPost.h"

#include <cstdlib>
#include <mutex>
#include <utility>
#include <vector>

#include "dart_api_dl.h"

namespace nitrohttp {
namespace {

/// The hook is a test seam swapped in before any engine exists, so contention is
/// nil — one lock per completed request, never per chunk. A mutex is used rather
/// than an unsynchronised `std::function` read because reading a `std::function`
/// while another thread assigns it is a data race, and "it only happens in
/// tests" is not a memory model.
std::mutex& postHookMutex() {
  static std::mutex m;
  return m;
}

PostHook& postHookSlot() {
  static PostHook hook;
  return hook;
}

BatchHook& batchHookSlot() {
  static BatchHook hook;
  return hook;
}

/// Frees every blob in a batch. Used on the paths where the batch cannot be
/// delivered — a dead port or an uninitialised Dart API — because the addresses
/// are the only surviving references to those allocations.
void releaseBatch(const std::vector<std::pair<int64_t, int64_t>>& items) {
  for (const auto& item : items) {
    auto* ptr = reinterpret_cast<uint8_t*>(static_cast<intptr_t>(item.second));
    if (ptr != nullptr) std::free(ptr);
  }
}

}  // namespace

bool dartPostAvailable() { return Dart_PostCObject_DL != nullptr; }

void setPostHook(PostHook hook) {
  std::lock_guard<std::mutex> lock(postHookMutex());
  postHookSlot() = std::move(hook);
}

bool postRecord(int64_t port, Blob blob) {
  {
    std::lock_guard<std::mutex> lock(postHookMutex());
    if (postHookSlot()) {
      // The hook receives ownership exactly as Dart_PostCObject_DL would.
      // Called under the lock: hooks never re-enter this function, and holding
      // it removes any window where a concurrent setPostHook could destroy the
      // callable mid-invocation.
      return postHookSlot()(port, blob);
    }
  }

  if (blob.empty()) {
    // Encoding the record failed (only OOM gets us here). The port must still
    // be completed or the Dart Future hangs forever, and `kNull` is precisely
    // the "could not even encode the envelope" signal — Dart's generated unpack
    // turns it into a HybridException.
    blob.release();
    return postNull(port);
  }

  if (!dartPostAvailable()) {
    blob.release();
    return false;
  }

  // Dart's generated unpack reads the message as an int, rebuilds the pointer
  // with `Pointer<Uint8>.fromAddress`, decodes, then calls the module's
  // `nitro_free`. Ownership transfers with the integer.
  Dart_CObject message{};
  message.type = Dart_CObject_kInt64;
  message.value.as_int64 = static_cast<int64_t>(reinterpret_cast<intptr_t>(blob.data));

  if (!Dart_PostCObject_DL(static_cast<Dart_Port_DL>(port), &message)) {
    // Dead port — hot restart tore the isolate down while this transfer was in
    // flight. Nobody else can free the blob now.
    blob.release();
    return false;
  }
  return true;
}

bool postCoalescedBatch(
    int64_t port, const std::vector<std::pair<int64_t, int64_t>>& items) {
  if (items.empty()) return true;

  {
    std::lock_guard<std::mutex> lock(postHookMutex());
    if (batchHookSlot()) return batchHookSlot()(port, items);
  }

  if (!dartPostAvailable()) {
    releaseBatch(items);
    return false;
  }

  // `[callId0, addr0, callId1, addr1, …]` — flat int64 pairs, which is what
  // `NitroCoalescer._onBatch` walks two at a time. The element array is built on
  // the stack-adjacent heap and only has to outlive the post call itself:
  // Dart_PostCObject_DL copies the message before returning.
  const size_t n = items.size() * 2;
  std::vector<Dart_CObject> elems(n);
  std::vector<Dart_CObject*> ptrs(n);
  for (size_t i = 0; i < items.size(); ++i) {
    elems[2 * i].type = Dart_CObject_kInt64;
    elems[2 * i].value.as_int64 = items[i].first;   // callId
    elems[2 * i + 1].type = Dart_CObject_kInt64;
    elems[2 * i + 1].value.as_int64 = items[i].second;  // blob address
  }
  for (size_t i = 0; i < n; ++i) ptrs[i] = &elems[i];

  Dart_CObject message{};
  message.type = Dart_CObject_kArray;
  message.value.as_array.length = static_cast<intptr_t>(n);
  message.value.as_array.values = ptrs.data();

  if (!Dart_PostCObject_DL(static_cast<Dart_Port_DL>(port), &message)) {
    // Dead port. Every blob in the batch is unreachable from Dart now, so the
    // whole burst has to be freed here — the single-post path does the same.
    releaseBatch(items);
    return false;
  }
  return true;
}

void setBatchHook(BatchHook hook) {
  std::lock_guard<std::mutex> lock(postHookMutex());
  batchHookSlot() = std::move(hook);
}

bool postNull(int64_t port) {
  {
    std::lock_guard<std::mutex> lock(postHookMutex());
    if (postHookSlot()) return postHookSlot()(port, Blob{});
  }
  if (!dartPostAvailable()) return false;

  Dart_CObject message{};
  message.type = Dart_CObject_kNull;
  return Dart_PostCObject_DL(static_cast<Dart_Port_DL>(port), &message);
}

}  // namespace nitrohttp
