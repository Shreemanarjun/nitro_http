# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — macOS toolchain for the dependency superbuild.
#
# One architecture per configure (BoringSSL cannot build fat binaries); the
# arm64 and x86_64 slices are combined by merge_apple.sh with `lipo -create`.
#
#   -DCMAKE_OSX_ARCHITECTURES=arm64   or   x86_64
#
# MACOSX_DEPLOYMENT_TARGET is 10.15 — Flutter's macOS floor.
#
# CMAKE_SYSTEM_NAME is deliberately NOT set: an x86_64 build on an arm64 host is
# still a native macOS build, and declaring a system name would set
# CMAKE_CROSSCOMPILING, which several of our dependencies read to disable
# host-tool execution they legitimately need.
# ─────────────────────────────────────────────────────────────────────────────

set(CMAKE_OSX_SYSROOT "macosx" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15" CACHE STRING "" FORCE)

if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "${CMAKE_HOST_SYSTEM_PROCESSOR}" CACHE STRING "" FORCE)
endif()

list(LENGTH CMAKE_OSX_ARCHITECTURES _nh_arch_count)
if(_nh_arch_count GREATER 1)
  message(FATAL_ERROR
    "nitro_http: CMAKE_OSX_ARCHITECTURES='${CMAKE_OSX_ARCHITECTURES}' names ${_nh_arch_count} "
    "architectures. BoringSSL cannot build fat binaries; build one arch at a time and run "
    "tool/deps/merge_apple.sh to combine them.")
endif()

if(NOT CMAKE_OSX_ARCHITECTURES MATCHES "^(arm64|x86_64)$")
  message(FATAL_ERROR
    "nitro_http: unsupported macOS architecture '${CMAKE_OSX_ARCHITECTURES}' (expected arm64 or x86_64).")
endif()
