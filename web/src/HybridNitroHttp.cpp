// HybridNitroHttp — web (WASM) implementation. Seeded once by nitrogen link
// from lib/src/generated/cpp/nitro_http.impl.g.cpp; never overwritten.
//
// TODO: implement all pure-virtual methods declared in HybridNitroHttp
//   While the line above exists, web keeps compiling the shared
//   src/HybridNitroHttp.cpp. Implement the methods, delete that line, and
//   re-run `nitrogen link` to build the module from this file instead.
//   The module is single-threaded: never block; post async results from
//   emscripten_async_call or a JS callback, not from a std::thread.
//
// Ownership conventions:
//   • Record/variant/tuple RETURNS, **emit_* stream items**, and record/
//     variant CALLBACK arguments you invoke a callback with: pass
//     writer.toNativeBuffer() (or nitro_<Variant>_to_native) — a malloc'd
//     [4B len][payload] block whose ownership transfers to the bridge/Dart.
//     Returning or emitting a non-owning writer.toBuffer() view is wrong:
//     Dart would decode-and-free a live local buffer.
//   • Record/variant PARAMS are non-owning payload views (no length prefix)
//     — copy if you need them after the call.
//   • TypedData RETURNS use NitroCppBuffer{ data, size } where size is in
//     BYTES, not elements (Float32List: count * sizeof(float)). A wrong
//     unit silently truncates the list Dart sees (bytes / elemSize).
//   • @zeroCopy TypedData returns are NOT copied by the bridge: return a
//     malloc'd buffer — ownership transfers, and the bridge frees it (via
//     <lib>_release_typed_data_return) when Dart's view is GC'd. Never
//     return a pointer to a member or stack buffer: it would be free()d.

#include "nitro_http.native.g.h"
#include <stdexcept>

// ── Implementation ───────────────────────────────────────────────────────────

class NitroHttpNativeImpl final : public HybridNitroHttpNative {
public:
    NitroHttpNativeImpl() = default;
    ~NitroHttpNativeImpl() override = default;

    // ── Methods ──────────────────────────────────────────────────────────────

    std::string engineVersion() override {
        // TODO: implement engineVersion
        throw std::runtime_error("Not implemented: engineVersion");
        // return "";
    }

    bool supportsHttp3() override {
        // TODO: implement supportsHttp3
        throw std::runtime_error("Not implemented: supportsHttp3");
        // return false;
    }

    bool supportsWebSockets() override {
        // TODO: implement supportsWebSockets
        throw std::runtime_error("Not implemented: supportsWebSockets");
        // return false;
    }

    bool supportsBrotli() override {
        // TODO: implement supportsBrotli
        throw std::runtime_error("Not implemented: supportsBrotli");
        // return false;
    }

    bool supportsZstd() override {
        // TODO: implement supportsZstd
        throw std::runtime_error("Not implemented: supportsZstd");
        // return false;
    }

    void resetNative() override {
        // TODO: implement resetNative
        throw std::runtime_error("Not implemented: resetNative");
    }

    void configureClient(NitroCppBuffer config) override {
        // TODO: implement configureClient
        throw std::runtime_error("Not implemented: configureClient");
    }

    void sendBuffered(NitroCppBuffer request, const uint8_t* body, size_t body_length, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: sendBuffered");
    }

    void sendBufferedCoalesced(int64_t callId, NitroCppBuffer request, const uint8_t* body, size_t body_length, int64_t dartPort) override {
        // TODO: implement sendBufferedCoalesced
        throw std::runtime_error("Not implemented: sendBufferedCoalesced");
    }

    void releaseRecord(int64_t address) override {
        // TODO: implement releaseRecord
        throw std::runtime_error("Not implemented: releaseRecord");
    }

    void startStreamed(NitroCppBuffer request, const uint8_t* body, size_t body_length, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: startStreamed");
    }

    void cancel(int64_t requestId) override {
        // TODO: implement cancel
        throw std::runtime_error("Not implemented: cancel");
    }

    void cancelAll() override {
        // TODO: implement cancelAll
        throw std::runtime_error("Not implemented: cancelAll");
    }

    void cancelToken(int64_t tokenId, const std::string& reason) override {
        // TODO: implement cancelToken
        throw std::runtime_error("Not implemented: cancelToken");
    }

    void releaseCancelToken(int64_t tokenId) override {
        // TODO: implement releaseCancelToken
        throw std::runtime_error("Not implemented: releaseCancelToken");
    }

    void grantCredit(int64_t requestId, int64_t chunkCount, int64_t ackedChunks) override {
        // TODO: implement grantCredit
        throw std::runtime_error("Not implemented: grantCredit");
    }

    int64_t feedUploadChunk(int64_t requestId, const uint8_t* chunk, size_t chunk_length) override {
        // TODO: implement feedUploadChunk
        throw std::runtime_error("Not implemented: feedUploadChunk");
        // return 0;
    }

    void finishUpload(int64_t requestId) override {
        // TODO: implement finishUpload
        throw std::runtime_error("Not implemented: finishUpload");
    }

    void failUpload(int64_t requestId, const std::string& message) override {
        // TODO: implement failUpload
        throw std::runtime_error("Not implemented: failUpload");
    }

    NitroCppBuffer getCookies(const std::string& url) override {
        // TODO: implement getCookies
        throw std::runtime_error("Not implemented: getCookies");
        // return { nullptr, 0 };
    }

    void setCookie(NitroCppBuffer cookie) override {
        // TODO: implement setCookie
        throw std::runtime_error("Not implemented: setCookie");
    }

    void clearCookies() override {
        // TODO: implement clearCookies
        throw std::runtime_error("Not implemented: clearCookies");
    }

    void flushCookies() override {
        // TODO: implement flushCookies
        throw std::runtime_error("Not implemented: flushCookies");
    }

    void configureCache(NitroCppBuffer config) override {
        // TODO: implement configureCache
        throw std::runtime_error("Not implemented: configureCache");
    }

    void prefetch(NitroCppBuffer request, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: prefetch");
    }

    void clearCache() override {
        // TODO: implement clearCache
        throw std::runtime_error("Not implemented: clearCache");
    }

    NitroCppBuffer cacheStats() override {
        // TODO: implement cacheStats
        throw std::runtime_error("Not implemented: cacheStats");
        // return { nullptr, 0 };
    }

    void wsConnect(NitroCppBuffer config, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: wsConnect");
    }

    int64_t wsSend(int64_t opcode, const uint8_t* payload, size_t payload_length) override {
        // TODO: implement wsSend
        throw std::runtime_error("Not implemented: wsSend");
        // return 0;
    }

    void wsClose(int64_t code, const std::string& reason) override {
        // TODO: implement wsClose
        throw std::runtime_error("Not implemented: wsClose");
    }

    void wsGrantCredit(int64_t frameCount, int64_t ackedFrames) override {
        // TODO: implement wsGrantCredit
        throw std::runtime_error("Not implemented: wsGrantCredit");
    }

    // ── Streams ──────────────────────────────────────────────────────────────
    // Call emit_<name>(item) from any thread to push items to Dart.
    // emit_* helpers are defined in the generated bridge.
    // Record/variant items: pass record.toNativeBuffer() — ownership of the
    // heap [4B len][payload] block transfers to the bridge (same convention
    // as record returns). Never emit a non-owning writer.toBuffer() view.
    // Example — start emitting from a background thread:
    //
    //   std::thread([this]{ emit_chunks(/* RawChunk value */); }).detach();
    //   std::thread([this]{ emit_events(/* NitroCppBuffer value */); }).detach();
    //   std::thread([this]{ emit_wsFrames(/* RawWsFrame value */); }).detach();
};

// ── Registration ─────────────────────────────────────────────────────────────
//
// Create a single instance and register it during plugin/app initialisation:
//
//   static NitroHttpNativeImpl g_impl;
//   nitro_http_register_impl(&g_impl);   // in your plugin init
//   nitro_http_register_impl(nullptr);   // in your plugin dispose
//
// On Flutter desktop (Windows / Linux / macOS with NativeImpl.cpp) add the
// registration call to your Flutter plugin's RegisterWithRegistrar:
//
//   void NitroHttpNativePlugin::RegisterWithRegistrar(PluginRegistrar* registrar) {
//       static NitroHttpNativeImpl impl;
//       nitro_http_register_impl(&impl);
//   }

// Registered when the wasm module instantiates.
namespace {
  struct _AutoRegister {
    _AutoRegister() { nitro_http_register_impl(new NitroHttpNativeImpl()); }
  };
  static _AutoRegister _auto_register_instance;
}
