# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — attach the C++ engine to the `nitro_http` shared library.
#
# Like src/deps.cmake this file is outside every section `nitrogen link`
# manages, so regeneration cannot clobber it. CI proves that by running
# `nitrogen link` followed by `git diff --exit-code`.
#
# Apple platforms never reach this file: CocoaPods and SwiftPM glob
# `Classes/` / `Sources/`, which forward to `src/HybridNitroHttp.cpp`, which
# `#include`s `engine/EngineUnity.cpp` unless NITRO_HTTP_ENGINE_SEPARATE_TUS
# is defined. Defining it here gives the CMake platforms one translation unit
# per source — better incremental builds and parallelism — while Apple gets a
# single unity TU with no per-file forwarders to maintain.
# ─────────────────────────────────────────────────────────────────────────────

include_guard(GLOBAL)

set(NITRO_HTTP_ENGINE_DIR "${CMAKE_CURRENT_LIST_DIR}/engine")

set(NITRO_HTTP_ENGINE_SOURCES
  "${NITRO_HTTP_ENGINE_DIR}/Common.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/ContentDecoder.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/Wire.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/DartPost.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/ClientConfig.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/CertStore.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/CancelRegistry.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/BodyPipe.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/ChunkArena.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/DeferredPayloads.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/RequestTask.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/CookieBridge.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/HttpCache.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/CurlEngine.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/WsSession.cpp"
  "${NITRO_HTTP_ENGINE_DIR}/EngineRegistry.cpp"
)

function(nitro_http_attach_engine target)
  target_sources(${target} PRIVATE ${NITRO_HTTP_ENGINE_SOURCES})
  target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
  target_compile_definitions(${target} PRIVATE NITRO_HTTP_ENGINE_SEPARATE_TUS)
  if(WIN32)
    # windows.h (pulled in through curl's winsock includes) defines min/max as
    # MACROS by default, which mangles every `std::min(...)` in the engine into
    # a syntax error (MSVC C2589/C2737, first seen in WsSession.cpp). NOMINMAX
    # is the documented off-switch; WIN32_LEAN_AND_MEAN shrinks the rest of the
    # macro surface while we are at it.
    target_compile_definitions(${target} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN
      # fopen/getenv are portable C; the _s variants MSVC pushes are not.
      _CRT_SECURE_NO_WARNINGS)
  endif()
  target_link_libraries(${target} PRIVATE nitro_http::curl nitro_http::platform)

  set_property(TARGET ${target} PROPERTY CXX_STANDARD 17)
  set_property(TARGET ${target} PROPERTY CXX_STANDARD_REQUIRED ON)
  set_property(TARGET ${target} PROPERTY VISIBILITY_INLINES_HIDDEN ON)
  set_property(TARGET ${target} PROPERTY C_VISIBILITY_PRESET hidden)
  set_property(TARGET ${target} PROPERTY CXX_VISIBILITY_PRESET hidden)

  if(MSVC)
    target_compile_options(${target} PRIVATE /EHsc /bigobj)
    # The plugin DLL is a self-contained C-ABI island. Forcing /MD in EVERY
    # configuration — including when the consuming app builds Debug — avoids
    # mixing /MDd and /MD CRTs across the static dependency archives.
    set_property(TARGET ${target} PROPERTY MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
  else()
    target_compile_options(${target} PRIVATE
      -ffunction-sections -fdata-sections -fno-strict-aliasing)
  endif()

  if(APPLE)
    target_link_options(${target} PRIVATE "-Wl,-dead_strip")
  elseif(UNIX)
    target_link_options(${target} PRIVATE "-Wl,--gc-sections")
    # Export only nitro_http_* — every dependency symbol stays internal so an
    # app linking its own libcurl cannot bind against ours.
    if(NOT ANDROID)
      target_link_options(${target} PRIVATE
        "-Wl,--version-script=${CMAKE_CURRENT_LIST_DIR}/nitro_http.map")
    endif()
  endif()
endfunction()
