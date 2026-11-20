#!/usr/bin/env bash
#
# Run the TLS probe (example/lib/benchmark/remote_tls_probe.dart) on a physical
# iPhone against a URL, and print its report: nitro_http over HTTP/2,
# nitro_http over HTTP/1.1 and dart:io, serial and in bursts.
#
#   # a server on this Mac, over Wi-Fi
#   PORT=$(tool/bench_native/h2tls/server.sh start)
#   tool/bench-ios-remote.sh "https://$(ipconfig getifaddr en0):$PORT/bytes/1024"
#   tool/bench_native/h2tls/server.sh stop
#
#   # any HTTP/2 host; keep the counts low against one that is not yours
#   BENCH_REMOTE_BURST=32 BENCH_REMOTE_BURSTS=5 BENCH_REMOTE_SERIAL=20 \
#     tool/bench-ios-remote.sh https://example.com/small
#
# The first run against the Mac makes iOS ask for Local Network access on the
# phone; until that is allowed every connection times out. BENCH_REMOTE_PIN
# resolves the host to one address in nitro_http, for when the clients would
# otherwise take different address families.
#
# Like bench-ios.sh, this installs a benchmark build over the example app and
# reads the report file back, because an iOS release build prints nothing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

URL="${1:-}"
[ -n "$URL" ] || { echo "usage: $0 <url>" >&2; exit 2; }

BUNDLE_ID="dev.shreeman.nitroHttpExample"
APP="example/build/ios/iphoneos/Runner.app"
OUT="build/bench/ios-remote-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

DEVICE="${NITRO_IOS_DEVICE:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -i "iPhone" | grep -v simulated |
           grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' |
           head -1)
fi
[ -n "$DEVICE" ] || { echo "no paired iPhone"; exit 1; }

DEFINES=(--dart-define=NITRO_HTTP_BENCHMARK=1 --dart-define=BENCH_PROBE=remote
         "--dart-define=BENCH_REMOTE_URL=$URL")
for name in BENCH_REMOTE_BURST BENCH_REMOTE_BURSTS BENCH_REMOTE_SERIAL \
            BENCH_REMOTE_COLD_BURSTS BENCH_REMOTE_PIN; do
  [ -n "${!name:-}" ] && DEFINES+=("--dart-define=$name=${!name}")
done

echo "==> building release"
( cd example && CARGO_PROFILE_RELEASE_STRIP=false flutter build ios --release "${DEFINES[@]}" ) \
  >"$OUT/build.log" 2>&1 || { echo "build failed — see $OUT/build.log"; exit 1; }

echo "==> installing"
installed=0
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$DEVICE" "$APP" >"$OUT/install.log" 2>&1; then
    installed=1; break
  fi
  sleep 5
done
[ "$installed" -eq 1 ] || { echo "install failed — see $OUT/install.log"; exit 1; }

REPORT="Documents/nitro_benchmark.md"
pull() {  # $1 = destination
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --user mobile --source "$REPORT" --destination "$1" >/dev/null 2>&1
}
# The previous run's report is still on the device; wait for a different one.
pull "$OUT/before.md"

echo "==> running"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" \
  >"$OUT/launch.log" 2>&1 || { echo "launch failed — see $OUT/launch.log"; exit 1; }
for _ in $(seq 1 90); do
  sleep 4
  pull "$OUT/report.tmp"
  if grep -q "NITRO_BENCH_END" "$OUT/report.tmp" 2>/dev/null &&
     ! cmp -s "$OUT/report.tmp" "$OUT/before.md"; then
    mv "$OUT/report.tmp" "$OUT/report.md"
    grep -v "NITRO_BENCH_END" "$OUT/report.md"
    exit 0
  fi
done
echo "no report after 6 minutes — see $OUT"
exit 1
