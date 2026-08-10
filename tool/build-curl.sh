#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — build the vendored libcurl stack with one command.
#
# A thin orchestrator over tool/deps/build.sh (one slice per invocation) and
# tool/deps/merge_apple.sh (folds the five Apple builds into
# NitroCurl.xcframework). It exists so "how do I build libcurl" has a one-line
# answer; everything below it is the same per-slice pipeline CI runs.
#
#   tool/build-curl.sh apple      # 5 Apple slices + xcframework merge
#   tool/build-curl.sh android    # arm64-v8a, armeabi-v7a, x86_64 (needs NDK)
#   tool/build-curl.sh linux      # host arch
#   tool/build-curl.sh all        # everything buildable from this host
#   tool/build-curl.sh --list     # print the plan without building
#
# Output lands in tool/deps/out/stage/<slice>/{include,lib} — exactly the
# layout NITRO_HTTP_DEPS_DIR consumes:
#
#   NITRO_HTTP_DEPS_DIR=$PWD/tool/deps/out/stage flutter build apk --release
#
# Windows is built by tool/deps/build.ps1 (MSVC + NASM + Ninja) and is not
# reachable from a POSIX shell, so it is deliberately absent here.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEPS=tool/deps

usage() {
  echo "usage: tool/build-curl.sh [apple|android|linux|all] [--list] [build.sh flags]" >&2
  exit 2
}

LIST_ONLY=0
TARGET=""
EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    apple|android|linux|all) [ -n "$TARGET" ] && usage; TARGET="$arg" ;;
    -*) EXTRA+=("$arg") ;;   # forwarded to build.sh (e.g. --no-http3)
    *) usage ;;
  esac
done
[ -z "$TARGET" ] && TARGET=all

plan() {
  case "$1" in
    apple)
      echo "build.sh --platform macos   --arch arm64"
      echo "build.sh --platform macos   --arch x86_64"
      echo "build.sh --platform ios     --arch arm64"
      echo "build.sh --platform ios-sim --arch arm64"
      echo "build.sh --platform ios-sim --arch x86_64"
      echo "merge_apple.sh"
      ;;
    android)
      # Needs ANDROID_NDK_HOME (r27+).
      echo "build.sh --platform android --arch arm64-v8a"
      echo "build.sh --platform android --arch armeabi-v7a"
      echo "build.sh --platform android --arch x86_64"
      ;;
    linux)
      local arch; arch=$(uname -m)
      case "$arch" in aarch64|arm64) arch=arm64 ;; *) arch=x64 ;; esac
      echo "build.sh --platform linux --arch $arch"
      ;;
    all)
      case "$(uname -s)" in
        Darwin) plan apple; plan android ;;
        Linux)  plan linux; plan android ;;
      esac
      ;;
    *) usage ;;
  esac
}

if [ "$LIST_ONLY" = 1 ]; then
  plan "$TARGET" | sed "s|^|  $DEPS/|"
  exit 0
fi

if plan "$TARGET" | grep -q "platform android" && [ -z "${ANDROID_NDK_HOME:-}" ]; then
  # Resolve the newest installed NDK rather than failing, matching Gradle.
  for sdk in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -d "$sdk/ndk" ]; then
      ANDROID_NDK_HOME="$sdk/ndk/$(ls "$sdk/ndk" | sort -V | tail -1)"
      export ANDROID_NDK_HOME
      echo "==> ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
      break
    fi
  done
fi

plan "$TARGET" | while read -r cmd; do
  # Extra flags apply to build.sh slices, not to the merge step.
  flags=""
  case "$cmd" in build.sh*) flags="${EXTRA[*]:-}" ;; esac
  echo "==> $DEPS/$cmd $flags"
  # shellcheck disable=SC2086
  (cd "$DEPS" && ./${cmd} $flags)
done

echo
echo "Done. Point the build at the result with:"
echo "  export NITRO_HTTP_DEPS_DIR=$PWD/$DEPS/out/stage"
