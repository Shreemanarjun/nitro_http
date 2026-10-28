#!/usr/bin/env bash
#
# Functional integration suites on macOS (desktop). Dual-use: CI and local.
#
#   bash example/tool/ci_macos_smoke.sh
#
# The six suites drive the client's features — GET/POST, response streaming,
# the disk cache, cookies, WebSockets, cancellation — against the example's
# in-app `shelf` server, all on the real native engine. Same six suites the iOS
# and Android smoke scripts run, so one set of behaviour is proven on every
# platform. Run one file per `flutter test` invocation: the macOS tool loses its
# log reader on a second app launch in one invocation.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter pub get
# Every functional suite: each integration_test/*_test.dart NOT tagged
# `benchmark` (those are the perf/profiling harnesses — tens of minutes,
# skip-by-default). Discovered dynamically so a new functional test is covered
# without editing this script.
suites=$(grep -L "@Tags.*benchmark" integration_test/*_test.dart | sort)
[ -n "$suites" ] || { echo "no functional integration suites found" >&2; exit 1; }
for f in $suites; do
  echo "== macos: $f =="
  flutter test -d macos "$f"
done
echo "macOS integration OK ($(printf '%s\n' "$suites" | wc -l | tr -d ' ') suites)"
