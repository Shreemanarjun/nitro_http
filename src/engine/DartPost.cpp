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

#include "dart_api_dl.h"

#ifdef NITRO_HTTP_TESTING
// The generated bridge header redefines `Dart_PostCObject_DL(port, obj)` to the
// exported `nitro_http_nitro_post`, which lives in `nitro_http.bridge.g.cpp` —
// deliberately not compiled into the test binaries, so a post can be intercepted
// through `setPostHook` without the completion-batch machinery or a live
// isolate. Dropping the macro here restores the direct call to Dart's own DL
// pointer — null until an isolate initialises it, which is exactly what the test
// wants: `dartPostAvailable()` is false and every post goes through the hook.
// This is the only engine TU that calls the symbol directly; everything else
// routes through `postRecord`.
#undef Dart_PostCObject_DL
#endif

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
