# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — iOS toolchain for the dependency superbuild.
#
# One architecture per configure. BoringSSL explicitly does not support
# multi-architecture builds, so fat slices are produced afterwards by
# `lipo -create` in merge_apple.sh.
#
#   -DNH_IOS_SDK=iphoneos         + -DCMAKE_OSX_ARCHITECTURES=arm64
#   -DNH_IOS_SDK=iphonesimulator  + -DCMAKE_OSX_ARCHITECTURES=arm64|x86_64
#
# IPHONEOS_DEPLOYMENT_TARGET is 13.0: Flutter's own floor, and the oldest
# release whose libcurl/BoringSSL builds we test.
# ─────────────────────────────────────────────────────────────────────────────

set(CMAKE_SYSTEM_NAME iOS)

if(NOT DEFINED NH_IOS_SDK OR NH_IOS_SDK STREQUAL "")
  set(NH_IOS_SDK "iphoneos")
endif()

if(NOT NH_IOS_SDK MATCHES "^(iphoneos|iphonesimulator)$")
  message(FATAL_ERROR
    "nitro_http: NH_IOS_SDK must be 'iphoneos' or 'iphonesimulator', got '${NH_IOS_SDK}'.")
endif()

set(CMAKE_OSX_SYSROOT "${NH_IOS_SDK}" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "" FORCE)

if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "" FORCE)
endif()

list(LENGTH CMAKE_OSX_ARCHITECTURES _nh_arch_count)
if(_nh_arch_count GREATER 1)
  message(FATAL_ERROR
    "nitro_http: CMAKE_OSX_ARCHITECTURES='${CMAKE_OSX_ARCHITECTURES}' names ${_nh_arch_count} "
    "architectures. BoringSSL cannot build fat binaries; build one arch at a time and run "
    "tool/deps/merge_apple.sh to combine them.")
endif()

# No iOS device is x86_64. If this fires, the SDK and the architecture have
# come from different places — most often because NH_IOS_SDK failed to reach a
# sub-build and defaulted back to `iphoneos`.
if(CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64" AND NH_IOS_SDK STREQUAL "iphoneos")
  message(FATAL_ERROR
    "nitro_http: x86_64 with the iphoneos SDK is not a real target. "
    "Use -DNH_IOS_SDK=iphonesimulator for x86_64.")
endif()

set(CMAKE_SYSTEM_PROCESSOR "${CMAKE_OSX_ARCHITECTURES}")

# CMake makes every executable a MACOSX_BUNDLE by default under CMAKE_SYSTEM_NAME=iOS.
# BoringSSL's install(TARGETS bssl) then fails with "no BUNDLE DESTINATION". We
# only want its two archives; the `bssl` tool is collateral, so make it a plain
# executable rather than an app bundle.
set(CMAKE_MACOSX_BUNDLE OFF)

# try_compile spawns a fresh CMake that re-reads this file but does not inherit
# ordinary variables; NH_IOS_SDK must travel with it or the probe would build
# for the device SDK while the real build targets the simulator.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES NH_IOS_SDK)

# The superbuild's staging prefix lives outside the SDK, and iOS pins
# find_library/find_path to CMAKE_FIND_ROOT_PATH. Without this a subproject's
# find_package would silently miss the dependency we just installed.
foreach(_nh_p IN LISTS CMAKE_PREFIX_PATH)
  list(APPEND CMAKE_FIND_ROOT_PATH "${_nh_p}")
endforeach()
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
