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
  echo "usage: tool/build-curl.sh [apple|android|linux|all] [--list] [--serial] [build.sh flags]" >&2
  exit 2
}

LIST_ONLY=0
SERIAL=0
TARGET=""
EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    --serial) SERIAL=1 ;;   # one slice at a time, live output — for debugging
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

# ── Run the slices ───────────────────────────────────────────────────────────
# Slices are independent, but each is internally a strict chain
# (boringssl → zlib → nghttp2 → nghttp3 → ngtcp2 → brotli → zstd → curl), so one
# slice leaves most of the machine idle however high --jobs goes. Running them
# together fills it; cores are divided rather than handed to each.
#
# Each slice logs to its own file because the output would otherwise interleave.
# --serial restores one-at-a-time live output, for watching a failing slice.
CORES=2
if command -v nproc >/dev/null 2>&1; then CORES="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then CORES="$(sysctl -n hw.ncpu)"; fi

SLICES=()
POST=()
while read -r cmd; do
  case "$cmd" in build.sh*) SLICES+=("$cmd") ;; *) POST+=("$cmd") ;; esac
done <<EOF
$(plan "$TARGET")
EOF

if [ "$SERIAL" = 1 ] || [ "${#SLICES[@]}" -le 1 ]; then
  for cmd in ${SLICES[@]+"${SLICES[@]}"}; do
    echo "==> $DEPS/$cmd ${EXTRA[*]:-}"
    # shellcheck disable=SC2086
    (cd "$DEPS" && ./${cmd} ${EXTRA[*]:-})
  done
else
  # Ceiling, not floor. Flooring 8 cores over 5 slices gives 1 job each and
  # leaves the machine at ~5/8 busy, because a slice is idle whenever it is
  # configuring, downloading or linking rather than compiling. Rounding up
  # oversubscribes slightly on purpose so those gaps get filled.
  per=$(( (CORES + ${#SLICES[@]} - 1) / ${#SLICES[@]} )); [ "$per" -lt 1 ] && per=1
  echo "==> ${#SLICES[@]} slices in parallel, $per job(s) each (of $CORES cores)"
  echo "    --serial builds them one at a time with live output"
  mkdir -p "$DEPS/out/logs"
  pids=()
  names=()
  for cmd in ${SLICES[@]+"${SLICES[@]}"}; do
    # Name the log after the slice, not the index, so a failure is findable.
    name=$(echo "$cmd" | sed 's/.*--platform \([^ ]*\).*--arch \([^ ]*\).*/\1-\2/')
    log="$DEPS/out/logs/$name.log"
    echo "    $name -> $log"
    # shellcheck disable=SC2086
    (cd "$DEPS" && ./${cmd} --jobs "$per" ${EXTRA[*]:-}) >"$log" 2>&1 &
    pids+=("$!")
    names+=("$name")
  done
  # bash 3.2 on macOS has no `wait -n`, so wait on each pid in turn and keep
  # going after a failure — reporting every broken slice beats reporting the
  # first one and hiding the rest.
  failed=()
  i=0
  while [ "$i" -lt "${#pids[@]}" ]; do
    if wait "${pids[$i]}"; then
      echo "==> ok   ${names[$i]}"
    else
      echo "==> FAIL ${names[$i]}  (see $DEPS/out/logs/${names[$i]}.log)"
      failed+=("${names[$i]}")
    fi
    i=$((i + 1))
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "${#failed[@]} slice(s) failed: ${failed[*]}"
    for n in ${failed[@]+"${failed[@]}"}; do
      echo "── tail of $n ──"
      tail -25 "$DEPS/out/logs/$n.log"
    done
    exit 1
  fi
fi

# The merge folds finished slices together, so it can only run once they are all
# present — never inside the parallel section above.
# bash 3.2 reads "${arr[@]}" on an EMPTY array as an unbound variable under
# `set -u`, and POST is empty for every target except apple — so this needs
# the ${arr[@]+...} guard or android/linux abort here rather than finishing.
for cmd in ${POST[@]+"${POST[@]}"}; do
  echo "==> $DEPS/$cmd"
  # shellcheck disable=SC2086
  (cd "$DEPS" && ./${cmd})
done

echo
echo "Done. Point the build at the result with:"
echo "  export NITRO_HTTP_DEPS_DIR=$PWD/$DEPS/out/stage"
