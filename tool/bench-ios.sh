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
# READING THE RESULT IS NOTHING LIKE THE OTHER TWO PLATFORMS. An iOS RELEASE
# build emits no `print` output at all — `devicectl device console` attaches
# happily and captures a zero-byte file, and `idevicesyslog` sees nothing
# either. Scraping the log here does not fail loudly; it just yields ten empty
# runs after polling 240 s each.
#
# That is exactly why the benchmark also writes its report into the app's
# Documents directory. This harness pulls that file off the device with
# `devicectl device copy from` and re-prefixes its table rows so the shared
# aggregator can read them, which is also why the run files here look like log
# output despite never having been logged.
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
REPORT="Documents/nitro_benchmark.md"
pull() {  # $1 = destination
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --user mobile --source "$REPORT" --destination "$1" >/dev/null 2>&1
}

for i in $(seq 1 "$RUNS"); do
  printf '  run %2d/%s ... ' "$i" "$RUNS"
  f=$(printf '%s/run-%02d.txt' "$OUT" "$i")
  md="$f.md"

  # The report is overwritten in place, so the previous run's copy is what tells
  # us when this run's has landed: pull the old one first and compare.
  prev="$OUT/.prev.md"
  rm -f "$prev"; pull "$prev"
  prev_sum=$(shasum "$prev" 2>/dev/null | cut -d' ' -f1)

  xcrun devicectl device process launch --device "$DEVICE" \
      --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1

  ok=0
  for _ in $(seq 1 40); do
    sleep 5
    rm -f "$md"; pull "$md" || continue
    grep -q "NITRO_BENCH_END" "$md" 2>/dev/null || continue
    [ "$(shasum "$md" 2>/dev/null | cut -d' ' -f1)" = "$prev_sum" ] && continue
    ok=1; break
  done

  if [ "$ok" -eq 1 ]; then
    # Re-prefix so tool/bench_aggregate.py, which keys on the log format the
    # other two platforms produce, can read a file that was never a log.
    sed -n 's/^\(|.*\)$/NITRO_BENCH \1/p' "$md" > "$f"
    echo "NITRO_BENCH NITRO_BENCH_END" >> "$f"
    p50=$(awk -F'|' '/\| small GET \| nitro_http /{print $7}' "$f" | tr -d ' ')
    echo "ok (small GET p50 $p50)"
  else
    : > "$f"
    echo "INVALID — no fresh report appeared; is the device unlocked?"
  fi
  rm -f "$md" "$prev"
  sleep "$SETTLE"
done

echo
python3 tool/bench_aggregate.py "$OUT"/run-*.txt
echo
echo "raw runs: $OUT"
