// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — unity translation unit for Apple builds.
//
// Podspecs glob `Classes/**/*` and SwiftPM globs `Sources/**`; neither can
// reference `../../src/engine/*.cpp` without one forwarder file per source, in
// four separate locations (ios/Classes, macos/Classes, and both SwiftPM
// `Sources/NitroHttpCpp/`). That is twelve files whose only job is to stay in
// sync with this directory listing.
//
// Instead `src/HybridNitroHttp.cpp` — which those locations already forward to —
// includes this file, and this file includes the engine. The CMake platforms
// define NITRO_HTTP_ENGINE_SEPARATE_TUS and compile each source on its own, so
// this TU is never part of a CMake build.
//
// Include order follows dependency order so a missing include in any individual
// source shows up as a build failure on the CMake platforms rather than being
// silently papered over here.
// ─────────────────────────────────────────────────────────────────────────────

#ifdef NITRO_HTTP_ENGINE_SEPARATE_TUS
#error "EngineUnity.cpp must not be compiled when the engine sources are built individually"
#endif

#include "Common.cpp"
#include "ContentDecoder.cpp"
#include "Wire.cpp"
#include "DartPost.cpp"
#include "ClientConfig.cpp"
#include "CertStore.cpp"
#include "CancelRegistry.cpp"
#include "BodyPipe.cpp"
#include "ChunkArena.cpp"
#include "DeferredPayloads.cpp"
#include "RequestTask.cpp"
#include "CookieBridge.cpp"
#include "HttpCache.cpp"
#include "CurlEngine.cpp"
#include "WsSession.cpp"
#include "EngineRegistry.cpp"
