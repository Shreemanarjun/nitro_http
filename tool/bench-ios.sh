#!/usr/bin/env bash
#
# Run the comparison benchmark N times on a physical iPhone or iPad.
#
#   tool/bench-ios.sh            # 10 runs (1 discarded as warm-up)
#   tool/bench-ios.sh 10 --keep  # reuse the built .app, skip the build
#
# A SIMULATOR CANNOT DO THIS. Flutter ships no AOT snapshot for the iOS
# simulator, so `--release` and `--profile` are both rejected there and a
# simulator can only ever report debug timings — which penalise Dart code far
# more than native code and therefore penalise each client differently. The
# preflight requires a real device.
#
# Reading the log is the part that differs from Android. There is no `logcat -d`
# equivalent: `devicectl device console` STREAMS and never returns, so it is
# started per run into a file, polled for the terminator, and killed. Without
# that it hangs the harness rather than the app.
#
# What is missing compared to the Android harness, honestly: iOS exposes no
# thermal zones to the host, so there is no gate equivalent to /sys/class/
# thermal. A fixed settle between runs is the best available substitute, and the
# aggregator's control-drift check is what actually catches a device that heated
# up — if the competitors move, the set is not comparable regardless of cause.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNS="${1:-10}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1
case "$RUNS" in ''|*[!0-9]*) echo "usage: $0 [runs] [--keep]" >&2; exit 2 ;; esac

BUNDLE_ID="dev.shreeman.nitroHttpExample"
APP="example/build/ios/iphoneos/Runner.app"
SETTLE=25              # seconds between runs, standing in for a thermal gate
OUT="build/bench/ios-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# ── Preflight ────────────────────────────────────────────────────────────────
fail=0
# Match the identifier by SHAPE, not by column position: `devicectl` prints a
# Model column containing spaces ("iPhone 12 (iPhone13,2)"), so counting fields
# from the right picks up the model and hands you "iPhone" as a device id.
# NITRO_IOS_DEVICE overrides the pick when more than one device is paired.
DEVICE="${NITRO_IOS_DEVICE:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -i "iPhone" |
           grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' |
           head -1)
fi
if [ -z "$DEVICE" ]; then
  echo "  REFUSE  no paired iPhone or iPad — a simulator cannot run a release build"
  fail=1
else
  model=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | sed 's/.*  \([A-Za-z].*\)$/\1/')
  echo "  ok      ${model:-device} ($DEVICE)"
fi

[ "$fail" -eq 1 ] && { echo; echo "Preflight failed."; exit 1; }

# ── Build and install once ───────────────────────────────────────────────────
if [ "$KEEP" = 1 ] && [ -d "$APP" ]; then
  echo "==> reusing the existing build"
else
  echo "==> building release (device build, signed)"
  ( cd example && flutter build ios --release \
      --dart-define=NITRO_HTTP_BENCHMARK=1 ) >"$OUT/build.log" 2>&1 \
    || { echo "build failed — see $OUT/build.log"; exit 1; }
fi
[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }

# A wireless pairing drops the control channel partway through a ~27 MB upload
# often enough that one attempt is not a fair test: the first try here failed
# with "Connection reset by peer" and the identical second try succeeded.
echo "==> installing"
installed=0
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$DEVICE" "$APP" >"$OUT/install.log" 2>&1; then
    installed=1; break
  fi
  echo "    attempt $attempt failed (wireless transport); retrying"
  sleep 5
done
if [ "$installed" -eq 0 ]; then
  echo "install failed after 3 attempts — see $OUT/install.log"
  echo "  a USB cable makes this reliable; wireless CoreDevice drops large uploads."
  exit 1
fi

# Launching is where an untrusted signing certificate shows up, and the error is
# not self-explanatory: FBSOpenApplicationServiceErrorDomain error 1 is
# RequestDenied, which reads like a bug in the harness rather than a one-time
# tap needed on the device. Check it once, up front, with the fix spelled out.
if ! xcrun devicectl device process launch --device "$DEVICE" \
        --terminate-existing "$BUNDLE_ID" >"$OUT/launch-probe.log" 2>&1; then
  if grep -q "RequestDenied" "$OUT/launch-probe.log"; then
    echo
    echo "  REFUSE  the app installed but iOS denied the launch (RequestDenied)."
    echo "          Trust the developer certificate once, on the device:"
    echo "          Settings > General > VPN & Device Management > trust"
    echo "          \"$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')\""
    exit 1
  fi
  echo "  launch probe failed — see $OUT/launch-probe.log"; exit 1
fi
xcrun devicectl device process terminate --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> $RUNS runs into $OUT"
for i in $(seq 1 "$RUNS"); do
  printf '  run %2d/%s ... ' "$i" "$RUNS"
  f=$(printf '%s/run-%02d.txt' "$OUT" "$i")
  raw="$f.raw"

  # Console first, app second: a fast run can finish its first scenario before a
  # late-started console attaches, and those lines are then simply gone.
  xcrun devicectl device console --device "$DEVICE" >"$raw" 2>/dev/null &
  console=$!
  sleep 3

  xcrun devicectl device process launch --device "$DEVICE" \
      --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1

  for _ in $(seq 1 120); do
    grep -q NITRO_BENCH_END "$raw" 2>/dev/null && break
    sleep 2
  done
  kill "$console" 2>/dev/null; wait "$console" 2>/dev/null

  grep "NITRO_BENCH" "$raw" > "$f" 2>/dev/null
  rm -f "$raw"

  if grep -q NITRO_BENCH_END "$f" 2>/dev/null; then
    p50=$(awk -F'|' '/\| small GET \| nitro_http /{print $7}' "$f" | tr -d ' ')
    echo "ok (small GET p50 $p50)"
  elif grep -q NITRO_BENCH_BEGIN "$f" 2>/dev/null; then
    echo "INVALID — started but never finished; is the screen locked?"
  else
    echo "INVALID — never started; check trust and that the device is unlocked"
  fi
  sleep "$SETTLE"
done

echo
python3 tool/bench_aggregate.py "$OUT"/run-*.txt
echo
echo "raw runs: $OUT"
