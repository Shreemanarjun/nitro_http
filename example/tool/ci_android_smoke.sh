#!/usr/bin/env bash
#
# Functional integration suites on an Android emulator or device. Dual-use: CI
# and local.
#
#   bash example/tool/ci_android_smoke.sh        # first device on adb
#   ANDROID_SERIAL=<serial> bash example/tool/ci_android_smoke.sh
#
# Runs the same six suites as the macOS and iOS smoke scripts. The engine builds
# from source for the device's ABI (arm64-v8a / armeabi-v7a / x86_64), so a
# plain x86_64 emulator works in CI — correctness, unlike a throughput
# benchmark, does not depend on real-device timing.
set -euo pipefail
cd "$(dirname "$0")/.."

adb wait-for-device
SERIAL="${ANDROID_SERIAL:-$(adb devices | awk '/\tdevice$/{print $1; exit}')}"
[ -n "$SERIAL" ] || { echo "no Android device on adb" >&2; exit 1; }
echo "device: $SERIAL"

flutter pub get
# Every functional suite (not tagged `benchmark`), discovered dynamically.
suites=$(grep -L "@Tags.*benchmark" integration_test/*_test.dart | sort)
[ -n "$suites" ] || { echo "no functional integration suites found" >&2; exit 1; }
for f in $suites; do
  echo "== android: $f =="
  flutter test -d "$SERIAL" "$f"
done
echo "Android integration OK ($(printf '%s\n' "$suites" | wc -l | tr -d ' ') suites)"
