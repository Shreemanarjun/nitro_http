# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — Android toolchain for the dependency superbuild.
#
# A thin wrapper over the NDK's own toolchain file. It exists to pin the two
# settings that must match the plugin's Gradle configuration exactly:
#
#   ANDROID_PLATFORM=24   — android/build.gradle's minSdk. A dependency built
#                           against a higher API level links fine and then
#                           fails to load on older devices with a dlopen error
#                           naming a symbol nobody recognises.
#   ANDROID_STL=c++_static — one C++ runtime, statically linked. BoringSSL and
#                           parts of curl's build compile C++; sharing
#                           libc++_shared with the app would make the plugin
#                           depend on the app's NDK version.
#
# Drive it with -DANDROID_ABI=arm64-v8a|armeabi-v7a|x86_64.
# ─────────────────────────────────────────────────────────────────────────────

set(NH_ANDROID_MIN_SDK 24)

if(NOT DEFINED ANDROID_NDK OR ANDROID_NDK STREQUAL "")
  foreach(_nh_env ANDROID_NDK_HOME ANDROID_NDK_ROOT ANDROID_NDK)
    if(DEFINED ENV{${_nh_env}} AND NOT "$ENV{${_nh_env}}" STREQUAL "")
      set(ANDROID_NDK "$ENV{${_nh_env}}")
      break()
    endif()
  endforeach()
endif()

if(NOT ANDROID_NDK)
  message(FATAL_ERROR
    "nitro_http: no Android NDK found.\n"
    "  Set ANDROID_NDK_HOME (or pass -DANDROID_NDK=<path>) to an NDK r27 or newer install.\n"
    "  e.g. export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/27.2.12479018")
endif()

if(NOT EXISTS "${ANDROID_NDK}/build/cmake/android.toolchain.cmake")
  message(FATAL_ERROR
    "nitro_http: '${ANDROID_NDK}' is not an NDK install "
    "(no build/cmake/android.toolchain.cmake).")
endif()

if(NOT DEFINED ANDROID_ABI OR ANDROID_ABI STREQUAL "")
  message(FATAL_ERROR
    "nitro_http: ANDROID_ABI is required. Pass -DANDROID_ABI=arm64-v8a, armeabi-v7a or x86_64.")
endif()

set(ANDROID_PLATFORM "android-${NH_ANDROID_MIN_SDK}")
set(ANDROID_STL "c++_static")

include("${ANDROID_NDK}/build/cmake/android.toolchain.cmake")

# The NDK toolchain restricts find_library/find_path to the sysroot. Our staging
# prefix is outside it, so add it as an additional root; CMake leaves paths that
# already sit under a root unrewritten, which is exactly what we want.
foreach(_nh_p IN LISTS CMAKE_PREFIX_PATH)
  list(APPEND CMAKE_FIND_ROOT_PATH "${_nh_p}")
endforeach()
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES ANDROID_NDK ANDROID_ABI ANDROID_PLATFORM ANDROID_STL)
