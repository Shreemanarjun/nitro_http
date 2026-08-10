// ─────────────────────────────────────────────────────────────────────────────
// nitro_http — the bridge implementation.
//
// This file is deliberately thin. It does exactly four things:
//
//   1. Registers a typed factory so each Dart-side instance key produces its own
//      C++ object with a `RoleHandle` (`engine` / `c:<id>` / `ws:<id>`).
//   2. Installs the process-global `StreamSink`, because the generated `emit_*`
//      helpers are members of the bridge class while the port registries they
//      write to are file-level statics keyed by stream NAME. The engine must not
//      depend on the generated class, so it goes through the sink instead.
//   3. Deep-copies every parameter before returning. Nitro releases the
//      parameter arena the instant a registering call returns, so retaining a
//      `NitroCppBuffer` or a `@zeroCopy` pointer past that point reads freed
//      memory. This is the single most dangerous contract in the plugin.
//   4. Delegates.
//
// On Apple platforms CocoaPods and SwiftPM glob `Classes/` / `Sources/`, which
// forward here, and the `#include` at the bottom pulls in the whole engine as
// one unity translation unit. The CMake platforms define
// NITRO_HTTP_ENGINE_SEPARATE_TUS and compile each engine source individually.
// ─────────────────────────────────────────────────────────────────────────────

#include "../lib/src/generated/cpp/nitro_http.native.g.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "engine/CancelRegistry.h"
#include "engine/Common.h"
#include "engine/CurlEngine.h"
#include "engine/DartPost.h"
#include "engine/EngineRegistry.h"
#include "engine/HttpCache.h"
#include "engine/Wire.h"
#include "engine/WsSession.h"

namespace {

using namespace nitrohttp;

class HybridNitroHttpImpl final : public HybridNitroHttpNative {
 public:
  explicit HybridNitroHttpImpl(const std::string& key)
      : role_(EngineRegistry::resolve(key)) {}

  ~HybridNitroHttpImpl() override = default;

  // ── Capabilities ───────────────────────────────────────────────────────────

  std::string engineVersion() override { return engineVersionString(); }
  bool supportsHttp3() override { return hasHttp3(); }
  bool supportsWebSockets() override { return hasWebSockets(); }
  bool supportsBrotli() override { return hasBrotli(); }
  bool supportsZstd() override { return hasZstd(); }

  void resetNative() override { EngineRegistry::resetAll(); }

  // ── Client role ────────────────────────────────────────────────────────────

  void configureClient(NitroCppBuffer config) override {
    role_.engine().configure(wire::decodeClientConfig(config));
  }

  void sendBuffered(NitroCppBuffer request, const uint8_t* body,
                    size_t body_length, NitroError*, int64_t dartPort) override {
    submit(request, body, body_length, RespMode::Buffered, dartPort);
  }

  void sendBufferedCoalesced(int64_t callId, NitroCppBuffer request,
                             const uint8_t* body, size_t body_length,
                             int64_t dartPort) override {
    // Same submission as `sendBuffered`; only the completion route differs, and
    // that is carried on the PendingRequest rather than branching the engine.
    submit(request, body, body_length, RespMode::Buffered, /*dartPort=*/0,
           dartPort, callId);
  }

  void releaseRecord(int64_t address) override {
    if (address == 0) return;
    // Same allocator that `Blob::copy` used, which is the whole reason this
    // crosses the bridge instead of being a `malloc.free` on the Dart side.
    std::free(reinterpret_cast<void*>(static_cast<intptr_t>(address)));
  }

  void startStreamed(NitroCppBuffer request, const uint8_t* body,
                     size_t body_length, NitroError*,
                     int64_t dartPort) override {
    submit(request, body, body_length, RespMode::Streamed, dartPort);
  }

  void cancel(int64_t requestId) override { role_.engine().cancel(requestId); }
  void cancelAll() override { role_.engine().cancelAll(); }

  void cancelToken(int64_t tokenId, const std::string& reason) override {
    // Order matters. The flag goes up FIRST, on this thread, so every bound
    // transfer that is currently inside a curl write/read/progress callback —
    // on any client, not just this instance's — aborts at its very next block
    // without waiting to be scheduled. Only then are the engines told, and that
    // notification exists purely for transfers running no callbacks at all.
    nitrohttp::CancelRegistry::instance().cancel(tokenId, reason);
    nitrohttp::EngineRegistry::cancelTokenEverywhere(tokenId);
  }

  void releaseCancelToken(int64_t tokenId) override {
    nitrohttp::CancelRegistry::instance().release(tokenId);
  }

  void grantCredit(int64_t requestId, int64_t chunkCount,
                   int64_t ackedChunks) override {
    role_.engine().grantCredit(requestId, chunkCount, ackedChunks);
  }

  int64_t feedUploadChunk(int64_t requestId, const uint8_t* chunk,
                          size_t chunk_length) override {
    // Copies inside the engine's ring before returning — the arena dies here.
    return role_.engine().feedUpload(requestId, chunk, chunk_length);
  }

  void finishUpload(int64_t requestId) override {
    role_.engine().finishUpload(requestId);
  }

  void failUpload(int64_t requestId, const std::string& message) override {
    role_.engine().failUpload(requestId, message);
  }

  NitroCppBuffer getCookies(const std::string& url) override {
    // The engine hands back the whole jar; Dart filters by domain and path.
    // `url` is accepted for API symmetry and future native filtering.
    (void)url;
    return wire::encodeCookieList(role_.engine().cookies()).toBuffer();
  }

  void setCookie(NitroCppBuffer cookie) override {
    role_.engine().setCookie(wire::decodeCookie(cookie));
  }

  void clearCookies() override { role_.engine().clearCookies(); }
  void flushCookies() override { role_.engine().flushCookies(); }

  // ── Engine role ────────────────────────────────────────────────────────────

  void configureCache(NitroCppBuffer config) override {
    role_.requireEngineRole();
    EngineRegistry::configureCache(wire::decodeCacheConfig(config));
  }

  void prefetch(NitroCppBuffer request, NitroError*, int64_t dartPort) override {
    role_.requireEngineRole();
    PendingRequest pending;
    pending.req = wire::decodeRequest(request);
    pending.mode = RespMode::Prefetch;
    pending.dartPort = dartPort;
    pending.submittedAtMs = monotonicMs();
    EngineRegistry::prefetchEngine().submit(std::move(pending));
  }

  void clearCache() override {
    role_.requireEngineRole();
    EngineRegistry::clearCache();
  }

  NitroCppBuffer cacheStats() override {
    role_.requireEngineRole();
    return wire::encodeCacheStats(EngineRegistry::cacheStats()).toBuffer();
  }

  // ── WebSocket role ─────────────────────────────────────────────────────────

  void wsConnect(NitroCppBuffer config, NitroError*, int64_t dartPort) override {
    role_.socket().connect(wire::decodeWsConfig(config), dartPort);
  }

  int64_t wsSend(int64_t opcode, const uint8_t* payload,
                 size_t payload_length) override {
    return role_.socket().send(opcode, payload, payload_length);
  }

  void wsClose(int64_t code, const std::string& reason) override {
    role_.socket().close(code, reason);
  }

  void wsGrantCredit(int64_t frameCount, int64_t ackedFrames) override {
    role_.socket().grantCredit(frameCount, ackedFrames);
  }

 private:
  /// `dartPort` and `coalescePort` are mutually exclusive: a request completes
  /// through its own port or through the shared batch, never both, because two
  /// posts would complete the same Dart call twice.
  void submit(NitroCppBuffer request, const uint8_t* body, size_t bodyLen,
              RespMode mode, int64_t dartPort, int64_t coalescePort = 0,
              int64_t coalesceCallId = -1) {
    PendingRequest pending;
    pending.req = wire::decodeRequest(request);  // deep copy
    if (body != nullptr && bodyLen > 0) {
      pending.body.assign(body, body + bodyLen);  // deep copy
    }
    pending.mode = mode;
    pending.dartPort = dartPort;
    pending.coalescePort = coalescePort;
    pending.coalesceCallId = coalesceCallId;
    pending.submittedAtMs = monotonicMs();
    role_.engine().submit(std::move(pending));
  }

  RoleHandle role_;
};

/// A deliberately leaked instance used purely as the receiver for the generated
/// `emit_*` member functions. Those functions never dereference `this` — they
/// only touch the file-level static port registries — but they are declared as
/// members, so the sink needs *some* object. Giving it process lifetime removes
/// any possibility of emitting through a destroyed instance.
HybridNitroHttpImpl* emitter() {
  static HybridNitroHttpImpl* instance = new HybridNitroHttpImpl("engine");
  return instance;
}

void installSink() {
  StreamSink sink;
  sink.chunk = [](RawChunk item) { emitter()->emit_chunks(item); };
  sink.event = [](NitroCppBuffer item) { emitter()->emit_events(item); };
  sink.wsFrame = [](RawWsFrame item) { emitter()->emit_wsFrames(item); };
  installStreamSink(std::move(sink));
}

std::shared_ptr<HybridNitroHttpNative> createInstance(const std::string& key) {
  return std::make_shared<HybridNitroHttpImpl>(key);
}

void registerEverything() {
  installSink();
  // `nitro_http_register_factory` copies the std::function, so handing it the
  // address of a local is correct here.
  nitro_http_register_factory_typed(HybridNitroHttpNativeFactory(createInstance));
}

}  // namespace

// ── Auto-registration on library load ────────────────────────────────────────
#if defined(_WIN32)
namespace {
struct AutoRegister {
  AutoRegister() { registerEverything(); }
};
AutoRegister g_autoRegister;
}  // namespace
#else
__attribute__((constructor)) static void nitro_http_auto_register() {
  registerEverything();
}
#endif

// ── Apple unity translation unit ─────────────────────────────────────────────
// CocoaPods and SwiftPM cannot reference `../src/engine/*.cpp` individually
// without a forwarder file per source. One `#include` here keeps the Apple
// build wiring at zero maintenance; CMake platforms compile the sources
// separately for better incremental builds.
#ifndef NITRO_HTTP_ENGINE_SEPARATE_TUS
#include "engine/EngineUnity.cpp"
#endif
