# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — dependency superbuild.
#
# Produces one self-contained slice: static archives + headers + manifest.json
# under ${CMAKE_INSTALL_PREFIX}, laid out exactly the way src/deps.cmake expects
# (`include/curl/curl.h` plus `lib/lib*.a`). CI runs this once per target and
# publishes the result as a `deps-vN` GitHub Release asset; app builds only ever
# download the result.
#
# Build order is a strict dependency chain:
#
#   boringssl → zlib → nghttp2 → nghttp3 → ngtcp2 → brotli → zstd → curl
#
# Never invoke this directly — use build.sh / build.ps1, which supply the
# toolchain file, the architecture and the output layout.
#
# Host requirements: CMake ≥ 3.22, git, Go (BoringSSL), a bash (Git Bash is
# fine on Windows), and NASM on Windows x86/x64.
# ─────────────────────────────────────────────────────────────────────────────

cmake_minimum_required(VERSION 3.22)

# Stamp extracted sources with the extraction time, so bumping a URL in
# deps/versions.cmake actually forces a rebuild instead of reusing objects
# built from the previous tarball.
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

# `C` — not `NONE`. The superbuild itself compiles nothing, but enabling C makes
# CMake process the toolchain file, which is what populates
# CMAKE_STATIC_LIBRARY_{PREFIX,SUFFIX} and the MSVC/Android/Apple detection this
# file keys off. With `NONE` every one of those would be empty.
project(nitro_http_deps VERSION 1.0.0 LANGUAGES C)

include(ExternalProject)
include("${CMAKE_CURRENT_LIST_DIR}/../../deps/versions.cmake")

find_package(Git REQUIRED)

option(NITRO_HTTP_ENABLE_HTTP3
       "Build ngtcp2 + nghttp3 and enable HTTP/3 in libcurl" ON)

if(NOT IS_ABSOLUTE "${CMAKE_INSTALL_PREFIX}")
  message(FATAL_ERROR
    "nitro_http deps: CMAKE_INSTALL_PREFIX must be absolute, got '${CMAKE_INSTALL_PREFIX}'.")
endif()

# ExternalProject splices these paths into command lines that are re-parsed by
# sub-builds; a space anywhere in them produces a truncated, baffling error
# several minutes into the build. Refuse up front instead.
foreach(_p "${CMAKE_INSTALL_PREFIX}" "${CMAKE_BINARY_DIR}" "${CMAKE_CURRENT_LIST_DIR}")
  if("${_p}" MATCHES "[ \t]")
    message(FATAL_ERROR
      "nitro_http deps: path '${_p}' contains whitespace.\n"
      "  Move the checkout, or point --out at a whitespace-free directory.")
  endif()
endforeach()

set(NH_PREFIX "${CMAKE_INSTALL_PREFIX}")
set(NH_DL     "${CMAKE_BINARY_DIR}/downloads")
set(NH_TOOLS  "${CMAKE_CURRENT_LIST_DIR}")

# BoringSSL's symbol-prefix flow lives in prefix_symbols.sh so that there is one
# implementation of it, usable both here and by hand. That costs us a bash
# dependency on Windows; Git for Windows provides one and the CI image has it.
find_program(NH_BASH NAMES bash sh)
if(NOT NH_BASH)
  message(FATAL_ERROR
    "nitro_http deps: no bash found on PATH.\n"
    "  BoringSSL is built through tool/deps/prefix_symbols.sh.\n"
    "  On Windows install Git for Windows (which ships bash.exe) and re-run.")
endif()

# ── Compile flags, identical for every component ─────────────────────────────
# Hidden visibility keeps the ~4 500 BoringSSL/curl symbols out of the plugin's
# dynamic symbol table; -ffunction-sections/-fdata-sections lets the final link
# garbage-collect the (large) unreferenced parts of libcrypto.
if(MSVC)
  set(NH_C_FLAGS   "/O2 /Ob2 /DNDEBUG /Gy /Gw /utf-8")
  set(NH_CXX_FLAGS "${NH_C_FLAGS} /EHsc /Zc:__cplusplus")
else()
  set(NH_C_FLAGS   "-O2 -DNDEBUG -fPIC -fvisibility=hidden -ffunction-sections -fdata-sections")
  # -fvisibility-inlines-hidden is C++-only; passing it to a C compile is at
  # best a warning and at worst an error under -Werror in a subproject.
  set(NH_CXX_FLAGS "${NH_C_FLAGS} -fvisibility-inlines-hidden")
endif()

set(NH_COMMON_ARGS
  "-DCMAKE_INSTALL_PREFIX=${NH_PREFIX}"
  # Some distributions default GNUInstallDirs to lib64; every consumer of a
  # slice (src/deps.cmake, the podspecs, the SPM manifests) hardcodes `lib`.
  "-DCMAKE_INSTALL_LIBDIR=lib"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  "-DBUILD_SHARED_LIBS=OFF"
  "-DBUILD_TESTING=OFF"
  "-DCMAKE_C_FLAGS=${NH_C_FLAGS}"
  "-DCMAKE_CXX_FLAGS=${NH_CXX_FLAGS}"
  "-DCMAKE_PREFIX_PATH=${NH_PREFIX}"
)

if(NOT MSVC)
  # BoringSSL compiles .S files through the C driver, so it wants the same
  # flags. On MSVC the assembler is NASM and reads CMAKE_ASM_NASM_FLAGS
  # instead — handing it /O2 would abort the build.
  list(APPEND NH_COMMON_ARGS "-DCMAKE_ASM_FLAGS=${NH_C_FLAGS}")
endif()

if(MSVC)
  # /MD in EVERY configuration. The plugin DLL is a self-contained C-ABI island,
  # so it must not inherit the consuming app's /MDd choice — mixing CRTs across
  # a static-library boundary corrupts anything allocated on one side and freed
  # on the other.
  list(APPEND NH_COMMON_ARGS
    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW"
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL")
endif()

# ── Toolchain passthrough ────────────────────────────────────────────────────
# ExternalProject does not inherit cross-compilation settings, so forward every
# variable the drivers may have set. Only defined, non-empty ones are passed:
# an empty -DCMAKE_OSX_SYSROOT= would override the SDK default with nothing.
foreach(_var
    CMAKE_TOOLCHAIN_FILE
    CMAKE_SYSTEM_NAME CMAKE_SYSTEM_VERSION CMAKE_SYSTEM_PROCESSOR
    CMAKE_OSX_ARCHITECTURES CMAKE_OSX_SYSROOT CMAKE_OSX_DEPLOYMENT_TARGET
    ANDROID_ABI ANDROID_PLATFORM ANDROID_NDK ANDROID_STL
    CMAKE_MAKE_PROGRAM CMAKE_ASM_NASM_COMPILER
    # Without this every sub-build re-reads ios.cmake, defaults NH_IOS_SDK to
    # `iphoneos` and FORCEs CMAKE_OSX_SYSROOT back to the device SDK — silently
    # producing a device-linked archive inside the simulator slice.
    NH_IOS_SDK)
  if(DEFINED ${_var} AND NOT "${${_var}}" STREQUAL "")
    list(APPEND NH_COMMON_ARGS "-D${_var}=${${_var}}")
  endif()
endforeach()

set(NH_EP_DEFAULTS
  PREFIX          "${CMAKE_BINARY_DIR}/ep"
  DOWNLOAD_DIR    "${NH_DL}"
  # Semicolons appear inside BORINGSSL_LIBRARIES; without this they would be
  # eaten as CMake list separators when ExternalProject re-parses CMAKE_ARGS.
  LIST_SEPARATOR  "|"
  USES_TERMINAL_DOWNLOAD  ON
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  USES_TERMINAL_INSTALL   ON
)

# Absolute paths to the archives we hand to downstream configures. Computed from
# the toolchain's own naming so the same expression is right for .a and .lib.
set(NH_LIBPRE "${CMAKE_STATIC_LIBRARY_PREFIX}")
set(NH_LIBEXT "${CMAKE_STATIC_LIBRARY_SUFFIX}")
function(nh_lib out name)
  set(${out} "${NH_PREFIX}/lib/${NH_LIBPRE}${name}${NH_LIBEXT}" PARENT_SCOPE)
endfunction()

nh_lib(NH_LIB_SSL      ssl)
nh_lib(NH_LIB_CRYPTO   crypto)
nh_lib(NH_LIB_Z        z)
nh_lib(NH_LIB_NGHTTP2  nghttp2)
nh_lib(NH_LIB_NGHTTP3  nghttp3)
nh_lib(NH_LIB_NGTCP2   ngtcp2)
nh_lib(NH_LIB_NGTCP2_BSSL ngtcp2_crypto_boringssl)
nh_lib(NH_LIB_BROTLICOMMON brotlicommon)
nh_lib(NH_LIB_BROTLIDEC    brotlidec)
nh_lib(NH_LIB_ZSTD     zstd)

# ── Archive normalisation ────────────────────────────────────────────────────
# Runs immediately after each dependency installs, and does two things:
#
#  1. Canonicalises names. MSVC builds decorate static archives (zlib emits
#     `zs.lib`, zstd `zstd_static.lib`), while src/deps.cmake, the podspecs and
#     the SPM manifests all look for the undecorated name. It has to happen
#     per-project rather than once at the end, because curl is handed
#     -DZLIB_LIBRARY=<prefix>/lib/z.lib and -DZSTD_LIBRARY=<prefix>/lib/zstd.lib
#     — paths that must already exist when curl configures.
#
#  2. On the final pass only: drops debug info and asserts libcurl landed.
#     BoringSSL hardcodes -ggdb into its own CMAKE_C_FLAGS *after* ours, so no
#     flag can turn it off, and it costs ~30 MB of DWARF that every consumer
#     would download on every clean build (libcrypto alone: 17 MB → 3 MB).
#     `strip -S` removes only debug sections — the global symbol table the
#     linker needs survives — and ranlib rebuilds the archive index.
set(NH_NORMALIZE_SCRIPT "${CMAKE_BINARY_DIR}/nh_normalize_libs.cmake")
file(WRITE "${NH_NORMALIZE_SCRIPT}" "\
# `built|canonical` pairs — a bare semicolon would flatten into the outer list.
set(_pairs
  \"zs|z\"
  \"zlibstatic|z\"
  \"zstd_static|zstd\"
  \"nghttp2_static|nghttp2\"
  \"nghttp3_static|nghttp3\"
  \"ngtcp2_static|ngtcp2\"
  \"ngtcp2_crypto_boringssl_static|ngtcp2_crypto_boringssl\"
  \"brotlicommon-static|brotlicommon\"
  \"brotlidec-static|brotlidec\"
  \"brotlienc-static|brotlienc\"
)
foreach(_pair IN LISTS _pairs)
  string(REPLACE \"|\" \";\" _parts \"\${_pair}\")
  list(GET _parts 0 _from)
  list(GET _parts 1 _to)
  set(_src \"\${NH_LIBDIR}/\${NH_PRE}\${_from}\${NH_EXT}\")
  set(_dst \"\${NH_LIBDIR}/\${NH_PRE}\${_to}\${NH_EXT}\")
  if(EXISTS \"\${_src}\" AND NOT EXISTS \"\${_dst}\")
    message(STATUS \"nitro_http deps: renaming \${_from}\${NH_EXT} -> \${_to}\${NH_EXT}\")
    file(RENAME \"\${_src}\" \"\${_dst}\")
  endif()
endforeach()

if(NOT NH_FINAL)
  return()
endif()

# A slice with no libcurl is worse than a failed build: src/deps.cmake would
# accept it and the app would fail at link time with hundreds of undefined
# curl_easy_* symbols. curl clears the library prefix and names the archive
# `libcurl` itself, so it is libcurl.a on Unix and libcurl.lib on MSVC.
if(NOT EXISTS \"\${NH_LIBDIR}/libcurl\${NH_EXT}\" AND
   NOT EXISTS \"\${NH_LIBDIR}/\${NH_PRE}curl\${NH_EXT}\")
  message(FATAL_ERROR
    \"nitro_http deps: \${NH_LIBDIR} contains no libcurl\${NH_EXT} after install.\")
endif()

if(NH_STRIP)
  file(GLOB _archives \"\${NH_LIBDIR}/*\${NH_EXT}\")
  foreach(_a IN LISTS _archives)
    execute_process(COMMAND \"\${NH_STRIP}\" -S \"\${_a}\"
                    RESULT_VARIABLE _rc ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
      message(FATAL_ERROR \"nitro_http deps: strip failed on \${_a}: \${_err}\")
    endif()
    if(NH_RANLIB)
      execute_process(COMMAND \"\${NH_RANLIB}\" \"\${_a}\"
                      RESULT_VARIABLE _rc ERROR_VARIABLE _err)
      if(NOT _rc EQUAL 0)
        message(FATAL_ERROR \"nitro_http deps: ranlib failed on \${_a}: \${_err}\")
      endif()
    endif()
  endforeach()
  message(STATUS \"nitro_http deps: stripped debug info from \${NH_LIBDIR}\")
endif()
")

function(nh_add_normalize_step target final)
  ExternalProject_Add_Step(${target} normalize_libs
    COMMAND "${CMAKE_COMMAND}"
            "-DNH_LIBDIR=${NH_PREFIX}/lib"
            "-DNH_PRE=${NH_LIBPRE}"
            "-DNH_EXT=${NH_LIBEXT}"
            "-DNH_FINAL=${final}"
            "-DNH_STRIP=${CMAKE_STRIP}"
            "-DNH_RANLIB=${CMAKE_RANLIB}"
            -P "${NH_NORMALIZE_SCRIPT}"
    COMMENT "Normalising static archives"
    DEPENDEES install
    ALWAYS ON
  )
endfunction()

# ── 1. BoringSSL ─────────────────────────────────────────────────────────────
# Pinned to a commit, not a tag: ngtcp2's boringssl crypto backend tracks
# specific snapshots (see deps/versions.cmake). Fetched with a depth-1 fetch of
# the exact SHA — git's own object hashing is the integrity check, so no
# separate archive checksum is needed.
#
# BORINGSSL_PREFIX=NH renames every exported symbol to NH_*. On Apple this is
# load-bearing rather than cosmetic: Nitro resolves through
# DynamicLibrary.process() and the plugin is statically linked into the app
# binary, so an app that also links OpenSSL (through any other plugin) would
# otherwise get two definitions of SSL_new/EVP_* silently deduplicated by the
# linker — different struct layouts, immediate memory corruption.
ExternalProject_Add(nh_boringssl
  ${NH_EP_DEFAULTS}
  DOWNLOAD_COMMAND  "${GIT_EXECUTABLE}" init --quiet <SOURCE_DIR>
            COMMAND "${GIT_EXECUTABLE}" -C <SOURCE_DIR> fetch --quiet --depth 1
                    https://github.com/google/boringssl.git "${NH_BORINGSSL_COMMIT}"
            COMMAND "${GIT_EXECUTABLE}" -C <SOURCE_DIR> checkout --quiet --force FETCH_HEAD
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     "${NH_BASH}" "${NH_TOOLS}/prefix_symbols.sh"
                    --src <SOURCE_DIR> --build <BINARY_DIR>
                    --prefix "${NH_PREFIX}" --symbol-prefix NH
                    # -G explicitly: this configure is ours, not
                    # ExternalProject's, so it inherits no generator. Without
                    # it CMake defaults to Makefiles while NH_COMMON_ARGS still
                    # forwards CMAKE_MAKE_PROGRAM=ninja, and the compiler probe
                    # dies with "ninja -f Makefile".
                    -- -G "${CMAKE_GENERATOR}" ${NH_COMMON_ARGS}
  INSTALL_COMMAND   ""
  BUILD_BYPRODUCTS  "${NH_LIB_SSL}" "${NH_LIB_CRYPTO}"
)

set(NH_LAST nh_boringssl)

# ── 2. zlib (Windows and Linux only) ─────────────────────────────────────────
# Apple SDKs and the Android NDK both ship libz in the sysroot; vendoring a
# second copy there would only risk two zlibs in one address space.
if(WIN32 OR (UNIX AND NOT APPLE AND NOT ANDROID))
  ExternalProject_Add(nh_zlib
    ${NH_EP_DEFAULTS}
    URL      "https://github.com/madler/zlib/releases/download/v${NH_ZLIB_VERSION}/zlib-${NH_ZLIB_VERSION}.tar.gz"
    URL_HASH "SHA256=${NH_ZLIB_SHA256}"
    CMAKE_ARGS ${NH_COMMON_ARGS}
      -DZLIB_BUILD_SHARED=OFF
      -DZLIB_BUILD_STATIC=ON
      -DZLIB_BUILD_TESTING=OFF
      -DZLIB_INSTALL=ON
    BUILD_BYPRODUCTS "${NH_LIB_Z}"
    DEPENDS ${NH_LAST}
  )
  set(NH_LAST nh_zlib)
  nh_add_normalize_step(nh_zlib OFF)
  set(NH_HAVE_VENDORED_ZLIB ON)
else()
  set(NH_HAVE_VENDORED_ZLIB OFF)
endif()

# ── 3. nghttp2 (HTTP/2) ──────────────────────────────────────────────────────
ExternalProject_Add(nh_nghttp2
  ${NH_EP_DEFAULTS}
  URL      "https://github.com/nghttp2/nghttp2/releases/download/v${NH_NGHTTP2_VERSION}/nghttp2-${NH_NGHTTP2_VERSION}.tar.xz"
  URL_HASH "SHA256=${NH_NGHTTP2_SHA256}"
  CMAKE_ARGS ${NH_COMMON_ARGS}
    -DENABLE_LIB_ONLY=ON
    -DBUILD_STATIC_LIBS=ON
    -DENABLE_DOC=OFF
    -DENABLE_HTTP3=OFF   # nghttp2's own h3 apps; curl gets h3 from ngtcp2.
    -DWITH_LIBXML2=OFF
    -DWITH_JEMALLOC=OFF
  BUILD_BYPRODUCTS "${NH_LIB_NGHTTP2}"
  DEPENDS ${NH_LAST}
)
set(NH_LAST nh_nghttp2)
nh_add_normalize_step(nh_nghttp2 OFF)

# ── 4./5. nghttp3 + ngtcp2 (HTTP/3) ──────────────────────────────────────────
# Roughly 40 % of a slice's byte size. NITRO_HTTP_ENABLE_HTTP3=OFF is the
# documented escape hatch for size-sensitive apps; the engine already reports
# h3 availability from curl_version_info() at runtime, so the Dart API behaves
# correctly either way.
if(NITRO_HTTP_ENABLE_HTTP3)
  ExternalProject_Add(nh_nghttp3
    ${NH_EP_DEFAULTS}
    URL      "https://github.com/ngtcp2/nghttp3/releases/download/v${NH_NGHTTP3_VERSION}/nghttp3-${NH_NGHTTP3_VERSION}.tar.xz"
    URL_HASH "SHA256=${NH_NGHTTP3_SHA256}"
    CMAKE_ARGS ${NH_COMMON_ARGS}
      -DENABLE_LIB_ONLY=ON
      -DENABLE_STATIC_LIB=ON
      -DENABLE_SHARED_LIB=OFF
    BUILD_BYPRODUCTS "${NH_LIB_NGHTTP3}"
    DEPENDS ${NH_LAST}
  )

  ExternalProject_Add(nh_ngtcp2
    ${NH_EP_DEFAULTS}
    URL      "https://github.com/ngtcp2/ngtcp2/releases/download/v${NH_NGTCP2_VERSION}/ngtcp2-${NH_NGTCP2_VERSION}.tar.xz"
    URL_HASH "SHA256=${NH_NGTCP2_SHA256}"
    CMAKE_ARGS ${NH_COMMON_ARGS}
      -DENABLE_LIB_ONLY=ON
      -DENABLE_STATIC_LIB=ON
      -DENABLE_SHARED_LIB=OFF
      -DENABLE_OPENSSL=OFF
      -DENABLE_BORINGSSL=ON
      "-DBORINGSSL_INCLUDE_DIR=${NH_PREFIX}/include"
      "-DBORINGSSL_LIBRARIES=${NH_LIB_SSL}|${NH_LIB_CRYPTO}"
      # ngtcp2 includes <openssl/*.h>; with a prefixed BoringSSL every public
      # name is a macro behind #if defined(BORINGSSL_PREFIX), so the define has
      # to reach the compile line or the backend links against NH_-less names.
      "-DCMAKE_C_FLAGS=${NH_C_FLAGS} -DBORINGSSL_PREFIX=NH"
      "-DCMAKE_CXX_FLAGS=${NH_CXX_FLAGS} -DBORINGSSL_PREFIX=NH"
    BUILD_BYPRODUCTS "${NH_LIB_NGTCP2}" "${NH_LIB_NGTCP2_BSSL}"
    DEPENDS nh_nghttp3
  )
  set(NH_LAST nh_ngtcp2)
  nh_add_normalize_step(nh_nghttp3 OFF)
  nh_add_normalize_step(nh_ngtcp2 OFF)
endif()

# ── 6. brotli ────────────────────────────────────────────────────────────────
ExternalProject_Add(nh_brotli
  ${NH_EP_DEFAULTS}
  URL      "https://github.com/google/brotli/archive/refs/tags/v${NH_BROTLI_VERSION}.tar.gz"
  URL_HASH "SHA256=${NH_BROTLI_SHA256}"
  CMAKE_ARGS ${NH_COMMON_ARGS}
    -DBROTLI_BUILD_TOOLS=OFF
    -DBROTLI_DISABLE_TESTS=ON
    -DBROTLI_BUILD_FOR_PACKAGE=OFF
  BUILD_BYPRODUCTS "${NH_LIB_BROTLICOMMON}" "${NH_LIB_BROTLIDEC}"
  DEPENDS ${NH_LAST}
)
set(NH_LAST nh_brotli)
nh_add_normalize_step(nh_brotli OFF)

# ── 7. zstd ──────────────────────────────────────────────────────────────────
ExternalProject_Add(nh_zstd
  ${NH_EP_DEFAULTS}
  URL            "https://github.com/facebook/zstd/releases/download/v${NH_ZSTD_VERSION}/zstd-${NH_ZSTD_VERSION}.tar.gz"
  URL_HASH       "SHA256=${NH_ZSTD_SHA256}"
  SOURCE_SUBDIR  "build/cmake"
  CMAKE_ARGS ${NH_COMMON_ARGS}
    -DZSTD_BUILD_STATIC=ON
    -DZSTD_BUILD_SHARED=OFF
    -DZSTD_BUILD_PROGRAMS=OFF
    -DZSTD_BUILD_TESTS=OFF
    -DZSTD_BUILD_CONTRIB=OFF
    # We only ever decompress a Content-Encoding: zstd response. Legacy format
    # support and the threaded compressor are pure size.
    -DZSTD_LEGACY_SUPPORT=OFF
    -DZSTD_MULTITHREAD_SUPPORT=OFF
  BUILD_BYPRODUCTS "${NH_LIB_ZSTD}"
  DEPENDS ${NH_LAST}
)
set(NH_LAST nh_zstd)
nh_add_normalize_step(nh_zstd OFF)

# ── 8. curl ──────────────────────────────────────────────────────────────────
# Deliberately narrow. Everything not needed by an HTTP client is off, both for
# size and because every enabled protocol is attack surface reachable from a
# redirect target.
#
# Dependencies are passed as explicit *_LIBRARY / *_INCLUDE_DIR cache variables
# instead of relying on find_library search order. Under the Android NDK and the
# iOS toolchains CMAKE_FIND_ROOT_PATH is pinned to the sysroot, so a plain
# find_library would never look inside our prefix — and, worse, on Linux it
# would happily pick up the host's shared libnghttp2 and produce an artifact
# that only links on the build machine.
set(NH_CURL_ARGS
  -DBUILD_CURL_EXE=OFF
  -DBUILD_STATIC_LIBS=ON
  -DBUILD_LIBCURL_DOCS=OFF
  -DBUILD_MISC_DOCS=OFF
  -DENABLE_CURL_MANUAL=OFF
  -DCURL_BUILD_EVERYTHING=OFF
  # Force module-mode detection with the explicit paths below. Config packages
  # and pkg-config would both reintroduce host-directory search.
  -DCURL_USE_CMAKECONFIG=OFF
  -DCURL_USE_PKGCONFIG=OFF

  # TLS: BoringSSL through curl's OpenSSL backend.
  -DCURL_ENABLE_SSL=ON
  -DCURL_USE_OPENSSL=ON
  # Deliberately OFF even though the libraries are static. It only steers
  # FindOpenSSL's *filename* search, which is moot here: OPENSSL_SSL_LIBRARY and
  # OPENSSL_CRYPTO_LIBRARY below name the archives outright.
  #
  # What it does change is that curl adds `stdc++` to CMAKE_REQUIRED_LIBRARIES
  # (permanently, outside any push/pop) when it detects BoringSSL under Clang,
  # on top of the `Threads::Threads` imported target it already added. Every
  # later curl_internal_test() then calls
  #   try_compile(... LINK_LIBRARIES "Threads::Threads;stdc++")
  # and CMake only resolves an imported target in LINK_LIBRARIES when the whole
  # value *is* that one target — with a second entry present it emits a bare
  # target_link_libraries(Threads::Threads) into the probe project, which fails
  # to generate. Configure dies at HAVE_FSETXATTR_5 and never reaches libcurl.
  #
  # Nothing is lost: `stdc++` would only have been recorded in libcurl's link
  # interface, which we never consume (src/deps.cmake links the archives
  # directly, and the plugin is itself C++ so the driver links the C++ runtime).
  -DOPENSSL_USE_STATIC_LIBS=OFF
  "-DOPENSSL_ROOT_DIR=${NH_PREFIX}"
  "-DOPENSSL_INCLUDE_DIR=${NH_PREFIX}/include"
  "-DOPENSSL_SSL_LIBRARY=${NH_LIB_SSL}"
  "-DOPENSSL_CRYPTO_LIBRARY=${NH_LIB_CRYPTO}"

  # BoringSSL renames its exports with `#pragma redefine_extname`, which only
  # takes effect for code that includes <openssl/*.h>. curl probes a few
  # functions with check_function_exists(), which declares the prototype itself
  # and includes nothing — so every such probe links against the unprefixed name
  # and reports "missing" for functions BoringSSL plainly has. Left alone, curl
  # would fall back to SSL_set_bio (different BIO-ownership semantics) and
  # HTTP/3 would be rejected outright with "QUICTLS API support is missing".
  #
  # Both names below are verified present in the installed
  # openssl/prefix_symbols.h, which is generated from BoringSSL's real export
  # list. curl skips a probe whose result is already defined.
  -DHAVE_SSL_SET0_WBIO=ON
  -DHAVE_SSL_SET_QUIC_USE_LEGACY_CODEPOINT=ON
  -DCURL_USE_SCHANNEL=OFF
  -DCURL_USE_MBEDTLS=OFF
  -DCURL_USE_WOLFSSL=OFF
  -DCURL_USE_GNUTLS=OFF
  -DCURL_USE_RUSTLS=OFF
  # Never bake a build-machine CA path into the artifact: trust is supplied at
  # runtime by CertStore (platform trust store, or a caller-provided bundle).
  -DCURL_CA_BUNDLE=none
  -DCURL_CA_PATH=none
  -DCURL_CA_FALLBACK=OFF

  # HTTP/2.
  -DUSE_NGHTTP2=ON
  "-DNGHTTP2_INCLUDE_DIR=${NH_PREFIX}/include"
  "-DNGHTTP2_LIBRARY=${NH_LIB_NGHTTP2}"

  # Compression.
  -DCURL_ZLIB=ON
  -DCURL_BROTLI=ON
  "-DBROTLI_INCLUDE_DIR=${NH_PREFIX}/include"
  "-DBROTLICOMMON_LIBRARY=${NH_LIB_BROTLICOMMON}"
  "-DBROTLIDEC_LIBRARY=${NH_LIB_BROTLIDEC}"
  -DCURL_ZSTD=ON
  "-DZSTD_INCLUDE_DIR=${NH_PREFIX}/include"
  "-DZSTD_LIBRARY=${NH_LIB_ZSTD}"

  # Resolution: thread-per-lookup instead of c-ares. One fewer vendored library,
  # and at our concurrency the thread cost is irrelevant next to the TLS
  # handshake it precedes.
  -DENABLE_THREADED_RESOLVER=ON
  -DENABLE_ARES=OFF

  # Kept on: everything the Dart API exposes.
  -DCURL_DISABLE_ALTSVC=OFF      # required for h3 discovery
  -DCURL_DISABLE_WEBSOCKETS=OFF
  -DCURL_DISABLE_COOKIES=OFF
  -DCURL_DISABLE_HSTS=OFF
  -DCURL_DISABLE_DOH=OFF
  -DCURL_DISABLE_PROXY=OFF
  -DCURL_DISABLE_MIME=OFF
  -DCURL_DISABLE_HEADERS_API=OFF

  # HTTP + HTTPS only. Note this is done with explicit CURL_DISABLE_* rather
  # than HTTP_ONLY, because HTTP_ONLY also force-disables WebSockets and
  # Alt-Svc, which we need.
  -DCURL_DISABLE_DICT=ON
  -DCURL_DISABLE_FILE=ON
  -DCURL_DISABLE_FTP=ON
  -DCURL_DISABLE_GOPHER=ON
  -DCURL_DISABLE_IMAP=ON
  -DCURL_DISABLE_IPFS=ON
  -DCURL_DISABLE_LDAP=ON
  -DCURL_DISABLE_LDAPS=ON
  -DCURL_DISABLE_MQTT=ON
  -DCURL_DISABLE_POP3=ON
  -DCURL_DISABLE_RTSP=ON
  -DCURL_DISABLE_SMTP=ON
  -DCURL_DISABLE_TELNET=ON
  -DCURL_DISABLE_TFTP=ON
  -DCURL_ENABLE_SMB=OFF

  # Auth schemes nobody reaches from a Flutter app, and which drag in
  # GSSAPI/SSPI. Basic/Bearer/Digest stay enabled.
  -DCURL_ENABLE_NTLM=OFF
  -DCURL_DISABLE_KERBEROS_AUTH=ON
  -DCURL_DISABLE_NEGOTIATE_AUTH=ON
  -DCURL_USE_GSSAPI=OFF
  -DCURL_WINDOWS_SSPI=OFF

  # Optional host libraries that curl auto-detects and would otherwise link
  # against whatever happens to be installed on the runner.
  -DCURL_USE_LIBSSH2=OFF
  -DCURL_USE_LIBSSH=OFF
  -DCURL_USE_GSASL=OFF
  -DCURL_USE_LIBUV=OFF
  -DCURL_USE_LIBBACKTRACE=OFF
  -DUSE_LIBIDN2=OFF
  -DUSE_WIN32_IDN=OFF
  -DUSE_APPLE_IDN=OFF

  # KNOWN GAP: libpsl is off, so curl's cookie engine cannot apply public-suffix
  # rules. A hostile server on `evil.co.uk` can therefore set a cookie for
  # `.co.uk`, and curl will send it to siblings under that suffix. Mitigations
  # today: cookies are per-client (never a process-global jar) and the Dart
  # CookieJar API lets an app inspect and drop them. The fix is to vendor a
  # minimal PSL and flip this to ON; it is tracked as a follow-up rather than
  # done here because libpsl pulls in libidn2 and ICU on most platforms.
  -DCURL_USE_LIBPSL=OFF
)

if(NITRO_HTTP_ENABLE_HTTP3)
  list(APPEND NH_CURL_ARGS
    -DUSE_NGTCP2=ON
    "-DNGTCP2_INCLUDE_DIR=${NH_PREFIX}/include"
    "-DNGTCP2_LIBRARY=${NH_LIB_NGTCP2}"
    "-DNGTCP2_CRYPTO_BORINGSSL_LIBRARY=${NH_LIB_NGTCP2_BSSL}"
    "-DNGHTTP3_INCLUDE_DIR=${NH_PREFIX}/include"
    "-DNGHTTP3_LIBRARY=${NH_LIB_NGHTTP3}")
else()
  list(APPEND NH_CURL_ARGS -DUSE_NGTCP2=OFF -DUSE_QUICHE=OFF)
endif()

if(NH_HAVE_VENDORED_ZLIB)
  list(APPEND NH_CURL_ARGS
    "-DZLIB_INCLUDE_DIR=${NH_PREFIX}/include"
    "-DZLIB_LIBRARY=${NH_LIB_Z}")
endif()

# curl's OpenSSL probes compile against <openssl/*.h>, which is prefixed.
set(NH_CURL_C_FLAGS   "${NH_C_FLAGS} -DBORINGSSL_PREFIX=NH")
set(NH_CURL_CXX_FLAGS "${NH_CXX_FLAGS} -DBORINGSSL_PREFIX=NH")
if(WIN32)
  # Without these, curl's includes of the ng* headers resolve to __declspec(dllimport)
  # declarations and the static link fails with unresolved __imp_ symbols.
  set(NH_CURL_C_FLAGS "${NH_CURL_C_FLAGS} -DNGHTTP2_STATICLIB -DNGHTTP3_STATICLIB -DNGTCP2_STATICLIB")
  list(APPEND NH_CURL_ARGS -DCURL_TARGET_WINDOWS_VERSION=0x0A00)
endif()

ExternalProject_Add(nh_curl
  ${NH_EP_DEFAULTS}
  URL      "https://curl.se/download/curl-${NH_CURL_VERSION}.tar.xz"
  URL_HASH "SHA256=${NH_CURL_SHA256}"
  CMAKE_ARGS ${NH_COMMON_ARGS} ${NH_CURL_ARGS}
    "-DCMAKE_C_FLAGS=${NH_CURL_C_FLAGS}"
    "-DCMAKE_CXX_FLAGS=${NH_CURL_CXX_FLAGS}"
  DEPENDS ${NH_LAST}
)

nh_add_normalize_step(nh_curl ON)

# ── manifest.json ────────────────────────────────────────────────────────────
# The single artefact that lets a bug report be traced back to an exact
# dependency set. The body is fixed at configure time; only the timestamp is
# filled in at build time, so it records when the shipped archive was produced.
if(ANDROID)
  set(NH_TARGET_ID "android-${ANDROID_ABI}")
elseif(WIN32)
  set(NH_TARGET_ID "windows-${CMAKE_SYSTEM_PROCESSOR}")
elseif(APPLE)
  if(CMAKE_OSX_ARCHITECTURES)
    set(NH_TARGET_ID "${CMAKE_SYSTEM_NAME}-${CMAKE_OSX_ARCHITECTURES}")
  else()
    set(NH_TARGET_ID "${CMAKE_SYSTEM_NAME}-${CMAKE_HOST_SYSTEM_PROCESSOR}")
  endif()
else()
  set(NH_TARGET_ID "${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
endif()

set(_nh_components
  "\"curl\": \"${NH_CURL_VERSION}\""
  "\"boringssl\": \"${NH_BORINGSSL_COMMIT}\""
  "\"boringsslPrefix\": \"NH\""
  "\"nghttp2\": \"${NH_NGHTTP2_VERSION}\"")
if(NITRO_HTTP_ENABLE_HTTP3)
  set(NH_MANIFEST_H3 "true")
  list(APPEND _nh_components
    "\"ngtcp2\": \"${NH_NGTCP2_VERSION}\""
    "\"nghttp3\": \"${NH_NGHTTP3_VERSION}\"")
else()
  set(NH_MANIFEST_H3 "false")
endif()
list(APPEND _nh_components
  "\"brotli\": \"${NH_BROTLI_VERSION}\""
  "\"zstd\": \"${NH_ZSTD_VERSION}\"")
if(NH_HAVE_VENDORED_ZLIB)
  list(APPEND _nh_components "\"zlib\": \"${NH_ZLIB_VERSION}\"")
else()
  list(APPEND _nh_components "\"zlib\": \"system\"")
endif()
string(JOIN ",\n    " NH_MANIFEST_COMPONENTS ${_nh_components})

set(NH_MANIFEST_TEMPLATE "${CMAKE_BINARY_DIR}/nh_manifest.json.in")
file(WRITE "${NH_MANIFEST_TEMPLATE}" "{
  \"schema\": 1,
  \"target\": \"${NH_TARGET_ID}\",
  \"builtAt\": \"@BUILT_AT@\",
  \"http3\": ${NH_MANIFEST_H3},
  \"components\": {
    ${NH_MANIFEST_COMPONENTS}
  },
  \"flags\": {
    \"c\": \"${NH_C_FLAGS}\",
    \"cxx\": \"${NH_CXX_FLAGS}\",
    \"msvcRuntime\": \"${CMAKE_MSVC_RUNTIME_LIBRARY}\"
  }
}
")

set(NH_MANIFEST_SCRIPT "${CMAKE_BINARY_DIR}/nh_write_manifest.cmake")
file(WRITE "${NH_MANIFEST_SCRIPT}" "\
string(TIMESTAMP _now \"%Y-%m-%dT%H:%M:%SZ\" UTC)
file(READ \"${NH_MANIFEST_TEMPLATE}\" _json)
string(REPLACE \"@BUILT_AT@\" \"\${_now}\" _json \"\${_json}\")
file(WRITE \"${NH_PREFIX}/manifest.json\" \"\${_json}\")
message(STATUS \"nitro_http deps: wrote ${NH_PREFIX}/manifest.json\")
")

add_custom_target(nh_manifest ALL
  COMMAND "${CMAKE_COMMAND}" -P "${NH_MANIFEST_SCRIPT}"
  COMMENT "Writing manifest.json"
  VERBATIM
)
add_dependencies(nh_manifest nh_curl)

message(STATUS "nitro_http deps: target=${NH_TARGET_ID} prefix=${NH_PREFIX} http3=${NITRO_HTTP_ENABLE_HTTP3}")
