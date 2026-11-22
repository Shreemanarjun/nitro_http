#!/usr/bin/env bash
#
# Build and run the native download source (see source.c) on this machine or
# on the connected Android device.
#
#   tool/bench_native/source/source.sh start macos   [port]   # prints the base URL
#   tool/bench_native/source/source.sh start android [port]
#   tool/bench_native/source/source.sh stop  macos|android
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ACTION="${1:-}"; TARGET="${2:-}"; PORT="${3:-18081}"
OUT="../../../build/bench/source"; mkdir -p "$OUT"
DEVICE_BIN=/data/local/tmp/nitro_http_source

usage() { echo "usage: $0 start|stop macos|android [port]" >&2; exit 2; }

case "$ACTION:$TARGET" in
  start:macos)
    cc -O2 -o "$OUT/source" source.c
    [ -f "$OUT/pid" ] && kill "$(cat "$OUT/pid")" 2>/dev/null || true
    "$OUT/source" "$PORT" >"$OUT/source.log" 2>&1 &
    pid=$!
    echo "$pid" > "$OUT/pid"
    # Ready means OUR child is alive and the port answers: a listener someone
    # else holds makes the child exit, which the second check catches.
    ready=0
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then ready=1; break; fi
      perl -e 'select(undef, undef, undef, 0.1)'
    done
    perl -e 'select(undef, undef, undef, 0.3)'
    if [ "$ready" != 1 ] || ! kill -0 "$pid" 2>/dev/null; then
      echo "source did not start on port $PORT:" >&2
      cat "$OUT/source.log" >&2
      kill "$pid" 2>/dev/null || true
      rm -f "$OUT/pid"
      exit 1
    fi
    echo "http://127.0.0.1:$PORT"
    ;;
  stop:macos)
    [ -f "$OUT/pid" ] && kill "$(cat "$OUT/pid")" 2>/dev/null || true
    rm -f "$OUT/pid"
    ;;
  start:android)
    NDK="${ANDROID_NDK_HOME:-$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/* 2>/dev/null | sort | tail -1)}"
    [ -d "$NDK" ] || { echo "no Android NDK found (set ANDROID_NDK_HOME)" >&2; exit 1; }
    HOST=$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)
    case "$(adb shell getprop ro.product.cpu.abi | tr -d '\r')" in
      arm64-v8a) TRIPLE=aarch64-linux-android24 ;;
      x86_64) TRIPLE=x86_64-linux-android24 ;;
      *) echo "unsupported device ABI" >&2; exit 1 ;;
    esac
    "$NDK/toolchains/llvm/prebuilt/$HOST/bin/clang" --target="$TRIPLE" -O2 -o "$OUT/source-android" source.c
    adb shell "pkill -f $DEVICE_BIN" >/dev/null 2>&1 || true
    adb push "$OUT/source-android" "$DEVICE_BIN" >/dev/null
    adb shell "chmod 755 $DEVICE_BIN"
    adb shell "nohup $DEVICE_BIN $PORT >$DEVICE_BIN.log 2>&1 &" >/dev/null 2>&1
    # The source exits at once when it cannot bind, so alive means listening.
    perl -e 'select(undef, undef, undef, 0.5)'
    if ! adb shell "pgrep -f $DEVICE_BIN" | grep -q '[0-9]'; then
      echo "source did not start on port $PORT:" >&2
      adb shell "cat $DEVICE_BIN.log" >&2 || true
      exit 1
    fi
    echo "http://127.0.0.1:$PORT"
    ;;
  stop:android)
    adb shell "pkill -f $DEVICE_BIN" >/dev/null 2>&1 || true
    ;;
  *) usage ;;
esac
