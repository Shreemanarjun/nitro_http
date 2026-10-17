#!/usr/bin/env bash
#
# Run the nitro_http benchmark AND the platform's native HTTP client against an
# identical device-local `shelf` server and the identical scenario set, then
# print one side-by-side table with a speedup column. This is the "how fast is
# nitro_http vs the platform's native client" answer, in one command.
#
#   tool/bench-compare.sh macos [runs]     # nitro_http vs Swift URLSession (this Mac)
#   tool/bench-compare.sh android [runs]   # nitro_http vs OkHttp (attached REAL device)
#
# Fairness is the whole point, so both sides are held identical:
#   * same server   — the native client hits the same `shelf` routes
#                     (tool/bench_serve.dart on macOS; lib/bench_serve_device.dart
#                     on the device for Android) the in-app nitro harness uses.
#   * same hardware — never across machines; on Android never across the USB
#                     tunnel (adb reverse caps throughput and skews small GETs),
#                     so the server runs ON the device and the client hits
#                     127.0.0.1 locally.
#   * same scenarios — SMALL_ITERS/TRANSFERS/BURST/BURST_REPS below mirror
#                     release_runner.dart, which is what the in-app harness runs.
#
# CI / non-interactive: BENCH_CI=1 downgrades the quiet-machine / thermal gates
# (see tool/bench-macos.sh, tool/bench-android.sh). Android is LOCAL-ONLY by
# design — an emulator's timings are not representative (tool/bench-android.sh
# refuses them for a reason), so CI only runs the macOS comparison, on a real
# Apple-silicon runner.
#
# Env tunables: SMALL_ITERS=10000 TRANSFERS=10 BURST=64 BURST_REPS=10
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PLATFORM="${1:-}"
RUNS="${2:-10}"
case "$PLATFORM" in macos|android) ;; *) echo "usage: $0 <macos|android> [runs]" >&2; exit 2 ;; esac
case "$RUNS" in ''|*[!0-9]*) echo "runs must be a number, got '$RUNS'" >&2; exit 2 ;; esac

SMALL_ITERS="${SMALL_ITERS:-10000}"
TRANSFERS="${TRANSFERS:-10}"
BURST="${BURST:-64}"
BURST_REPS="${BURST_REPS:-10}"
APP_ID="dev.shreeman.nitro_http_example"

# BENCH_KEEP=1 reuses the already-built nitro benchmark app (passes --keep to
# the underlying bench script) — a fast re-run when only the native side or the
# formatting changed. Left empty expands to zero args (bash 3.2 safe).
KEEP_FLAG=""
[ "${BENCH_KEEP:-0}" = 1 ] && KEEP_FLAG="--keep"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="build/bench/compare-$PLATFORM-$STAMP"
mkdir -p "$OUT"
NATIVE="$OUT/native.txt"

# bench-macos.sh / bench-android.sh each print `raw runs: <dir>` as their final
# line; that is where their NITRO_BENCH run files landed.
nitro_dir_from() { grep -oE "raw runs: .*" "$1" | tail -1 | sed 's/raw runs: //'; }

run_macos() {
  local bin="$OUT/nativebench" url="" pid=""
  # SPM is broken under Xcode 27 (-target-arch-variant), so compile directly.
  echo "==> native: compiling Swift URLSession bench"
  xcrun swiftc -O tool/bench_native/swift/Sources/nativebench/main.swift -o "$bin"

  echo "==> native: starting host shelf server"
  ( cd example && dart run tool/bench_serve.dart >"../$OUT/serve.log" 2>&1 ) &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; pkill -f bench_serve.dart 2>/dev/null || true' RETURN
  # `|| true` + an `if` test: under `set -e`/`pipefail` a grep that has not yet
  # matched (exit 1) would otherwise abort the whole poll on the first tick.
  for _ in $(seq 1 120); do
    url=$(grep -oE "BENCH_SERVER_URL http://[0-9.]+:[0-9]+" "$OUT/serve.log" 2>/dev/null | awk '{print $2}' | head -1) || true
    if [ -n "$url" ]; then break; fi
    sleep 0.5
  done
  [ -n "$url" ] || { echo "host server did not start:"; cat "$OUT/serve.log"; return 1; }
  echo "    server $url"

  echo "==> native: URLSession run"
  "$bin" "$url" "$SMALL_ITERS" "$TRANSFERS" "$BURST" "$BURST_REPS" | tee "$NATIVE"
  kill "$pid" 2>/dev/null || true; pkill -f bench_serve.dart 2>/dev/null || true

  echo "==> nitro_http: $RUNS run(s)"
  bash tool/bench-macos.sh "$RUNS" $KEEP_FLAG | tee "$OUT/nitro.log"
  local ndir; ndir=$(nitro_dir_from "$OUT/nitro.log") || true
  [ -n "$ndir" ] || { echo "could not find nitro run dir"; return 1; }
  python3 tool/bench_compare.py --platform "macOS (Apple silicon, loopback)" \
    --native-name URLSession --nitro "$ndir/run-*.txt" --native "$NATIVE" | tee "$OUT/comparison.md"
}

run_android() {
  command -v adb >/dev/null 2>&1 || { echo "adb not on PATH" >&2; return 1; }

  # nitro first: it builds+installs+runs its own benchmark APK (its own in-app
  # device-local server). Then the native half installs the serve APK over it.
  echo "==> nitro_http: $RUNS run(s) on the attached device"
  bash tool/bench-android.sh "$RUNS" $KEEP_FLAG | tee "$OUT/nitro.log"
  local ndir; ndir=$(nitro_dir_from "$OUT/nitro.log") || true
  [ -n "$ndir" ] || { echo "could not find nitro run dir"; return 1; }

  echo "==> native: building OkHttp dex"
  local dex; dex=$(tool/bench_native/android/build-dex.sh | tail -1)
  echo "    dex $dex"
  adb push "$dex" /data/local/tmp/benchdex.jar >/dev/null

  echo "==> native: building + installing device-local server APK"
  local abi tp
  abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
  case "$abi" in
    arm64*)   tp=android-arm64 ;;
    x86_64)   tp=android-x64 ;;
    armeabi*) tp=android-arm ;;
    *)        tp=android-arm64 ;;
  esac
  ( cd example && flutter build apk --release \
      --target lib/bench_serve_device.dart --target-platform "$tp" ) >"$OUT/serve-build.log" 2>&1 \
    || { echo "serve APK build failed — see $OUT/serve-build.log"; return 1; }
  adb install -r example/build/app/outputs/flutter-apk/app-release.apk >"$OUT/serve-install.log" 2>&1

  adb logcat -c >/dev/null 2>&1
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
  adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  local url=""
  for _ in $(seq 1 120); do
    url=$(adb logcat -d -s flutter:I 2>/dev/null | grep -oE "BENCH_SERVE_URL=http://[0-9.]+:[0-9]+" | tail -1 | cut -d= -f2-) || true
    if [ -n "$url" ]; then break; fi
    sleep 0.5
  done
  [ -n "$url" ] || { echo "device server did not start (check $OUT/serve-install.log)"; return 1; }
  echo "    device-local server $url"

  echo "==> native: OkHttp run"
  adb shell "CLASSPATH=/data/local/tmp/benchdex.jar app_process /data/local/tmp OkHttpBenchKt $url $SMALL_ITERS $TRANSFERS $BURST $BURST_REPS" | tee "$NATIVE"
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1

  local model; model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  python3 tool/bench_compare.py --platform "Android ($model, device-local)" \
    --native-name OkHttp --nitro "$ndir/run-*.txt" --native "$NATIVE" \
    --note "Both device-local (no adb-reverse tunnel). Record the per-run CPU temp from the nitro log; a hot phone throttles both clients." | tee "$OUT/comparison.md"
}

case "$PLATFORM" in
  macos)   run_macos ;;
  android) run_android ;;
esac

echo
echo "comparison: $OUT/comparison.md"
echo "artifacts:  $OUT"
