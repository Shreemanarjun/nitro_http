cmake_minimum_required(VERSION 3.10)
project(nitro_http_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Optimization guard ───────────────────────────────────────────────────────
# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as
# CMAKE_BUILD_TYPE. CMake only defines per-config flags for
# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag
# sets, so every native source silently compiles at -O0. Flutter's release
# variant maps to RELEASE and is unaffected, but profile builds shipped
# unoptimized native code. Give any non-standard config Release-grade flags.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _NITRO_CFG)
if(NOT "${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)$")
  # -O3 to match what CMake's own Release config implies, so a Flutter profile
  # build is not quietly a notch slower than release on the same source.
  set(CMAKE_C_FLAGS_${_NITRO_CFG} "-O3 -DNDEBUG")
  set(CMAKE_CXX_FLAGS_${_NITRO_CFG} "-O3 -DNDEBUG")
endif()

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 532789d18515e810
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_http SHARED
  "nitro_http.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_http.bridge.g.cpp"
  "dart_api_dl.c"
)

if(NOT ANDROID)
  if(DEFINED NITRO_IMPL_SRC_nitro_http)
    target_sources(nitro_http PRIVATE "${NITRO_IMPL_SRC_nitro_http}")
  else()
    target_sources(nitro_http PRIVATE "HybridNitroHttp.cpp")
  endif()
endif()
target_include_directories(nitro_http PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_http PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(nitro_http PRIVATE android log)
  target_link_options(nitro_http PRIVATE "-Wl,-z,max-page-size=16384")
endif()

# ── nitro_http engine ────────────────────────────────────────────────────────
# Everything below is hand-maintained but lives OUTSIDE every section
# `nitrogen link` rewrites, so regeneration cannot clobber it. All real logic
# is in the two included files.
#
# The block above only compiles the impl TU when NOT ANDROID, because the
# scaffold assumed Android went through Kotlin/JNI. The spec is C++ on every
# platform now, so Android needs it too.
if(ANDROID)
  target_sources(nitro_http PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/HybridNitroHttp.cpp")
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/deps.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/engine.cmake")
nitro_http_attach_engine(nitro_http)

# ── Tests (desktop only, opt-in) ─────────────────────────────────────────────
option(NITRO_HTTP_BUILD_TESTS "Build the C++ engine test suite" OFF)
if(NITRO_HTTP_BUILD_TESTS)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../test/cpp"
                   "${CMAKE_CURRENT_BINARY_DIR}/nitro_http_tests")
endif()
