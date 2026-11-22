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
# A suite that has not finished in SUITE_LIMIT seconds is stopped, its app's
# state and recent log are printed, and it is run once more: on a CI runner the
# test app can stall after launch, which otherwise holds the job until its time
# limit with no output at all.
SUITE_LIMIT="${SUITE_LIMIT:-900}"
run_suite() {  # $1 = suite; returns flutter's status, or 124 when stopped
  flutter test -d "$UDID" "$1" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$SUITE_LIMIT" ]; then
      echo "!! $1 still running after ${SUITE_LIMIT}s; diagnostics:"
      xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -i runner || echo "   no Runner process"
      xcrun simctl spawn "$UDID" log show --last 3m --style compact \
        --predicate 'process == "Runner"' 2>/dev/null | tail -40 || true
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      xcrun simctl terminate "$UDID" dev.shreeman.nitroHttpExample 2>/dev/null || true
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$pid"
}

for f in $suites; do
  echo "== ios-sim: $f =="
  status=0
  run_suite "$f" || status=$?
  if [ "$status" = 124 ]; then
    echo "== ios-sim: $f (retry after a stall) =="
    run_suite "$f"
  elif [ "$status" != 0 ]; then
    exit "$status"
  fi
done
echo "iOS-simulator integration OK ($(printf '%s\n' "$suites" | wc -l | tr -d ' ') suites)"
