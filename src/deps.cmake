# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — resolve libcurl (and its TLS/HTTP stack) for the current target.
#
# This file is NEVER touched by `nitrogen link`, which manages sections of
# src/CMakeLists.txt. All dependency logic lives here so regeneration cannot
# clobber it.
#
# Resolution order, first match wins:
#
#   1. NITRO_HTTP_DEPS_DIR  — a directory containing `include/` and `lib/`.
#      For air-gapped builds, corporate proxies, or local superbuild output.
#      Also read from the environment variable of the same name.
#
#   2. Prebuilt archive from GitHub Releases, SHA-256 pinned in
#      deps/versions.cmake. Extracted into a cache directory OUTSIDE the build
#      tree so it survives `flutter clean`. This is the path Android and iOS
#      take, because neither ships a system libcurl.
#
#   3. System libcurl. The default on Linux, macOS and Windows-with-vcpkg,
#      where a perfectly good libcurl already exists and asking developers to
#      download a 3 MB archive to run the test suite is silly.
#
# Whichever path runs, it defines the same interface target:
#
#   nitro_http::curl   — include dirs + link libraries, transitively.
#
# Transport features (HTTP/2, HTTP/3) are NOT baked in here: the engine asks
# `curl_version_info()` at runtime and reports through `hasHttp3()`, so one
# binary behaves correctly against any libcurl build.
#
# CONTENT CODINGS are the opposite. `CURLOPT_HTTP_CONTENT_DECODING` is off and
# src/engine/ContentDecoder.cpp does the inflating, so what matters is what OUR
# decoder is linked against, which is a build-time fact this file owns:
#
#   NITRO_HTTP_HAS_ZLIB    always — every supported platform ships zlib
#   NITRO_HTTP_HAS_BROTLI  when a vendored slice provides brotlidec + its header
#   NITRO_HTTP_HAS_ZSTD    when a vendored slice provides zstd + its header
#
# Never gate these on `curl_version_info`: that reports what CURL can decode,
# which is now irrelevant, and it is exactly the mismatch that made the plugin
# behave differently on a vendored Android slice and a macOS system curl.
# ─────────────────────────────────────────────────────────────────────────────

include_guard(GLOBAL)

include("${CMAKE_CURRENT_LIST_DIR}/../deps/versions.cmake")

option(NITRO_HTTP_ALLOW_SYSTEM_CURL
       "Permit falling back to a system libcurl when no vendored slice is available"
       ON)

# ── Target slice identification ──────────────────────────────────────────────
function(_nh_slice_name out)
  if(ANDROID)
    set(${out} "android-${ANDROID_ABI}" PARENT_SCOPE)
  elseif(WIN32)
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
      set(${out} "windows-x64" PARENT_SCOPE)
    else()
      set(${out} "windows-x86" PARENT_SCOPE)
    endif()
  elseif(APPLE)
    set(${out} "apple-xcframework" PARENT_SCOPE)
  elseif(UNIX)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
      set(${out} "linux-arm64" PARENT_SCOPE)
    else()
      set(${out} "linux-x64" PARENT_SCOPE)
    endif()
  else()
    set(${out} "unknown" PARENT_SCOPE)
  endif()
endfunction()

_nh_slice_name(NH_SLICE)

# ── Path 1: explicit local directory ─────────────────────────────────────────
if(NOT NITRO_HTTP_DEPS_DIR AND DEFINED ENV{NITRO_HTTP_DEPS_DIR})
  set(NITRO_HTTP_DEPS_DIR "$ENV{NITRO_HTTP_DEPS_DIR}")
endif()

set(_nh_root "")

if(NITRO_HTTP_DEPS_DIR)
  # Accept either <dir> or <dir>/<slice> so one env var can serve every ABI.
  foreach(_cand "${NITRO_HTTP_DEPS_DIR}/${NH_SLICE}" "${NITRO_HTTP_DEPS_DIR}")
    if(EXISTS "${_cand}/include/curl/curl.h")
      set(_nh_root "${_cand}")
      break()
    endif()
  endforeach()
  if(NOT _nh_root)
    message(FATAL_ERROR
      "nitro_http: NITRO_HTTP_DEPS_DIR='${NITRO_HTTP_DEPS_DIR}' does not contain "
      "include/curl/curl.h (looked in that directory and in its '${NH_SLICE}' subdirectory).")
  endif()
  message(STATUS "nitro_http: using dependencies from NITRO_HTTP_DEPS_DIR=${_nh_root}")
endif()

# ── Path 2: checksum-pinned prebuilt archive ─────────────────────────────────
if(NOT _nh_root)
  set(_nh_sha "${NH_SLICE_${NH_SLICE}_SHA256}")
  # A cache OUTSIDE the build tree: `flutter clean` must not force a re-download.
  if(DEFINED ENV{NITRO_HTTP_DEPS_CACHE})
    set(_nh_cache "$ENV{NITRO_HTTP_DEPS_CACHE}")
  else()
    set(_nh_cache "${CMAKE_CURRENT_LIST_DIR}/../.nitro_http_deps")
  endif()
  set(_nh_dest "${_nh_cache}/${NITRO_HTTP_DEPS_RELEASE}/${NH_SLICE}")

  if(EXISTS "${_nh_dest}/include/curl/curl.h")
    set(_nh_root "${_nh_dest}")
    message(STATUS "nitro_http: using cached prebuilt dependencies at ${_nh_root}")
  elseif(_nh_sha)
    set(_nh_url "${NITRO_HTTP_DEPS_BASE_URL}/nitro-curl-${NH_SLICE}.tar.gz")
    set(_nh_tgz "${_nh_cache}/nitro-curl-${NH_SLICE}.tar.gz")
    message(STATUS "nitro_http: downloading ${_nh_url}")
    file(DOWNLOAD "${_nh_url}" "${_nh_tgz}"
         EXPECTED_HASH "SHA256=${_nh_sha}"
         SHOW_PROGRESS STATUS _nh_dl)
    list(GET _nh_dl 0 _nh_dl_code)
    if(NOT _nh_dl_code EQUAL 0)
      list(GET _nh_dl 1 _nh_dl_msg)
      message(FATAL_ERROR
        "nitro_http: failed to download prebuilt dependencies (${_nh_dl_msg}).\n"
        "  URL: ${_nh_url}\n"
        "\n"
        "  If that URL looks wrong, this build directory is serving a stale\n"
        "  CMake cache rather than deps/versions.cmake — delete android/.cxx\n"
        "  (Gradle keeps one per ABI) or the CMake build directory and retry.\n"
        "  A 'HASH mismatch' whose actual hash is e3b0c442...b855 is the same\n"
        "  thing: that is the SHA-256 of an empty file, so the download 404'd.\n"
        "\n"
        "  Otherwise set NITRO_HTTP_DEPS_DIR to a directory holding include/ and\n"
        "  lib/, or build them with tool/deps/build.sh --platform ... --arch ...")
    endif()
    file(MAKE_DIRECTORY "${_nh_dest}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xzf "${_nh_tgz}"
                    WORKING_DIRECTORY "${_nh_dest}" RESULT_VARIABLE _nh_x)
    if(NOT _nh_x EQUAL 0)
      message(FATAL_ERROR "nitro_http: failed to extract ${_nh_tgz}")
    endif()
    set(_nh_root "${_nh_dest}")
  endif()
endif()

# Compile definitions that tell src/engine/ContentDecoder.cpp which codings it
# may compile in. zlib is unconditional; the branches below add the rest.
set(_nh_decoder_defs NITRO_HTTP_HAS_ZLIB=1)

# ── Consume a vendored slice ─────────────────────────────────────────────────
if(_nh_root)
  add_library(nitro_http::curl INTERFACE IMPORTED GLOBAL)
  target_include_directories(nitro_http::curl INTERFACE "${_nh_root}/include")

  # Link order matters for static archives on GNU ld: curl first, then the
  # protocol libraries, then crypto, then compression.
  set(_nh_link "")
  foreach(_lib curl nghttp3 ngtcp2_crypto_boringssl ngtcp2 nghttp2
               ssl crypto brotlidec brotlienc brotlicommon zstd z)
    # NO_CMAKE_FIND_ROOT_PATH is load-bearing on Android. The NDK toolchain sets
    # CMAKE_FIND_ROOT_PATH to the NDK and CMAKE_FIND_ROOT_PATH_MODE_LIBRARY to
    # ONLY, which makes find_library re-root even an explicit PATHS entry under
    # the NDK — so a slice anywhere else on disk is invisible and every lookup
    # returns NOTFOUND. That is the one platform with no system libcurl to fall
    # back to, so the whole vendored path (NITRO_HTTP_DEPS_DIR *and* the
    # downloaded prebuilt archive) failed with "no libraries found under".
    # Harmless everywhere else: Apple and Windows leave the mode at BOTH.
    find_library(_nh_lib_${_lib} NAMES ${_lib} lib${_lib}
                 PATHS "${_nh_root}/lib" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    if(_nh_lib_${_lib})
      list(APPEND _nh_link "${_nh_lib_${_lib}}")
    endif()
  endforeach()

  # Library AND header: they install from the same prefix, so a slice built
  # without brotli is missing both. Checking the header too turns a
  # misconfigured slice into a CMake-time silence rather than a compile error.
  if(_nh_lib_brotlidec AND EXISTS "${_nh_root}/include/brotli/decode.h")
    list(APPEND _nh_decoder_defs NITRO_HTTP_HAS_BROTLI=1)
  endif()
  if(_nh_lib_zstd AND EXISTS "${_nh_root}/include/zstd.h")
    list(APPEND _nh_decoder_defs NITRO_HTTP_HAS_ZSTD=1)
  endif()
  if(NOT _nh_link)
    message(FATAL_ERROR "nitro_http: no libraries found under ${_nh_root}/lib")
  endif()
  target_link_libraries(nitro_http::curl INTERFACE ${_nh_link})
  target_compile_definitions(nitro_http::curl INTERFACE CURL_STATICLIB)

# ── Path 3: system libcurl ───────────────────────────────────────────────────
elseif(NITRO_HTTP_ALLOW_SYSTEM_CURL)
  find_package(CURL QUIET)
  if(NOT CURL_FOUND)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(NH_PC_CURL QUIET libcurl)
    endif()
  endif()

  if(CURL_FOUND)
    add_library(nitro_http::curl INTERFACE IMPORTED GLOBAL)
    if(TARGET CURL::libcurl)
      target_link_libraries(nitro_http::curl INTERFACE CURL::libcurl)
    else()
      target_include_directories(nitro_http::curl INTERFACE ${CURL_INCLUDE_DIRS})
      target_link_libraries(nitro_http::curl INTERFACE ${CURL_LIBRARIES})
    endif()
    message(STATUS "nitro_http: using system libcurl ${CURL_VERSION_STRING}")
  elseif(NH_PC_CURL_FOUND)
    add_library(nitro_http::curl INTERFACE IMPORTED GLOBAL)
    target_include_directories(nitro_http::curl INTERFACE ${NH_PC_CURL_INCLUDE_DIRS})
    target_link_libraries(nitro_http::curl INTERFACE ${NH_PC_CURL_LIBRARIES})
    target_link_directories(nitro_http::curl INTERFACE ${NH_PC_CURL_LIBRARY_DIRS})
    message(STATUS "nitro_http: using system libcurl ${NH_PC_CURL_VERSION} (pkg-config)")
  else()
    message(FATAL_ERROR
      "nitro_http: no libcurl for slice '${NH_SLICE}'.\n"
      "  • Record a SHA-256 for NH_SLICE_${NH_SLICE}_SHA256 in deps/versions.cmake\n"
      "    to enable the prebuilt download, or\n"
      "  • set NITRO_HTTP_DEPS_DIR to a directory containing include/ and lib/, or\n"
      "  • install a development libcurl (e.g. `apt install libcurl4-openssl-dev`).")
  endif()
else()
  message(FATAL_ERROR
    "nitro_http: no vendored dependency slice for '${NH_SLICE}' and "
    "NITRO_HTTP_ALLOW_SYSTEM_CURL is OFF.")
endif()

# ── Platform system libraries the engine itself needs ────────────────────────
add_library(nitro_http::platform INTERFACE IMPORTED GLOBAL)
if(ANDROID)
  target_link_libraries(nitro_http::platform INTERFACE z log android)
elseif(WIN32)
  # crypt32 → CURLSSLOPT_NATIVE_CA (CryptoAPI ROOT store); bcrypt → RNG;
  # iphlpapi → if_nametoindex, which curl's connection code calls for IPv6
  # scope ids (LNK2019 in libcurl.lib(peer.c.obj) without it).
  target_link_libraries(nitro_http::platform INTERFACE ws2_32 crypt32 bcrypt iphlpapi)
elseif(APPLE)
  # Security/CoreFoundation → SecTrust chain validation in CertStore.
  # SystemConfiguration → SCDynamicStoreCopyProxies, which curl's lib/macos.c
  # calls for system-proxy discovery whenever CURL_DISABLE_PROXY is off. Since
  # ProxySettings.system() is a supported feature, that call is not optional and
  # a vendored static libcurl fails to link without this framework.
  target_link_libraries(nitro_http::platform INTERFACE
    "-framework Security" "-framework CoreFoundation"
    "-framework SystemConfiguration" z resolv)
elseif(UNIX)
  target_link_libraries(nitro_http::platform INTERFACE z dl pthread)
endif()

# The decoder macros ride on `platform` rather than `curl`, because they describe
# the ENGINE's capabilities. The C++ test binary links this target too, so the
# decoder tests compile against exactly the same set the plugin ships with.
target_compile_definitions(nitro_http::platform INTERFACE ${_nh_decoder_defs})
message(STATUS "nitro_http: engine content codings — ${_nh_decoder_defs}")
