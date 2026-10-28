#!/usr/bin/env bash
#
# Functional integration suites on an iOS simulator. Dual-use: CI and local.
#
#   bash example/tool/ci_ios_smoke.sh            # first available iPhone sim
#   SIMULATOR_UDID=<udid> bash example/tool/ci_ios_smoke.sh
#
# Boots an iPhone simulator and runs the same six suites as the macOS and
# Android smoke scripts. A simulator (not a device) because Flutter has no
# release AOT for the simulator but debug integration tests run fine, and a
# simulator needs no provisioning — which is what makes this runnable in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${SIMULATOR_UDID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
for runtime in sorted(devs, reverse=True):          # newest iOS runtime first
    if "iOS" in runtime:
        for d in devs[runtime]:
            if d["name"].startswith("iPhone"):
                print(d["udid"]); sys.exit()
')}"
[ -n "$UDID" ] || { echo "no iPhone simulator available" >&2; exit 1; }
echo "simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

flutter pub get
# Every functional suite (not tagged `benchmark`), discovered dynamically.
suites=$(grep -L "@Tags.*benchmark" integration_test/*_test.dart | sort)
[ -n "$suites" ] || { echo "no functional integration suites found" >&2; exit 1; }
for f in $suites; do
  echo "== ios-sim: $f =="
  flutter test -d "$UDID" "$f"
done
echo "iOS-simulator integration OK ($(printf '%s\n' "$suites" | wc -l | tr -d ' ') suites)"
