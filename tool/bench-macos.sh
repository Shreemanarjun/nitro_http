#!/usr/bin/env bash
#
# Run the macOS comparison benchmark N times and aggregate the result.
#
#   tool/bench-macos.sh            # 10 runs (1 discarded as warm-up)
#   tool/bench-macos.sh 20         # 20 runs
#   tool/bench-macos.sh 10 --keep  # keep an existing build, skip rebuilding
#
# Why a loop and not one run: a single run of this suite has flipped the fastest
# client in four of five scenarios. Ten runs is the point where the aggregator
# can separate a real gap from this laptop, and it costs about five minutes.
#
# Why the binary is executed directly rather than through `flutter run`: the
# tool never exits after the app calls exit(), so a loop built on it deadlocks
# on the first iteration. Build once, exec many.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNS="${1:-10}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1
case "$RUNS" in ''|*[!0-9]*) echo "usage: $0 [runs] [--keep]" >&2; exit 2 ;; esac

APP="example/build/macos/Build/Products/Release/nitro_http_example.app"
BIN="$APP/Contents/MacOS/nitro_http_example"
OUT="build/bench/macos-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# ── Preflight ────────────────────────────────────────────────────────────────
# Refuse rather than warn. A benchmark that runs anyway produces numbers someone
# will quote later, and by then nobody remembers the machine was busy.
fail=0

power=$(pmset -g ps 2>/dev/null | head -1)
case "$power" in
  *"AC Power"*) echo "  ok      on AC power" ;;
  *) echo "  REFUSE  on battery — macOS caps clocks off AC"; fail=1 ;;
esac

if [ "$(pmset -g 2>/dev/null | awk '/lowpowermode/{print $2}')" = "1" ]; then
  echo "  REFUSE  Low Power Mode is on"; fail=1
else
  echo "  ok      Low Power Mode off"
fi

cores=$(sysctl -n hw.ncpu)
load=$(uptime | sed 's/.*load averages*: *//' | awk '{print $1}')
# One busy core out of eight is tolerable; half the machine is not.
if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c/2)}'; then
  echo "  REFUSE  load $load on $cores cores — something else is running"; fail=1
else
  echo "  ok      load $load on $cores cores"
fi

# How busy the machine is RIGHT NOW.
#
# Two traps here, both of which produced a wrong answer before this comment
# existed. Matching on process names cries wolf: a Mac with Xcode installed
# always has CoreSimulator helpers and `xcdevice observe` alive, and they are
# idle. And `ps -o %cpu` is a LIFETIME average on macOS — total CPU time over
# elapsed time since the process started — so anything long-lived that was busy
# an hour ago still reads hot while doing nothing. `top -l 2` samples twice and
# discards the first; the second sample is a true interval.
sample=$(top -l 2 -n 5 -stats cpu,command 2>/dev/null | awk '/^CPU usage/{s++} s==2')
idle=$(printf '%s\n' "$sample" |
  awk '/^CPU usage/{for (i = 1; i <= NF; i++) if ($i == "idle") {gsub(/%/, "", $(i-1)); print $(i-1); exit}}')
if [ -z "$idle" ]; then
  echo "  ok      could not sample CPU (top unavailable) — proceeding"
elif awk -v i="$idle" 'BEGIN{exit !(i < 70)}'; then
  top1=$(printf '%s\n' "$sample" | awk 'NR>10 && $1+0 > 5 {print $1"% "$2; exit}')
  echo "  REFUSE  only ${idle}% idle${top1:+ (busiest: $top1)}"; fail=1
else
  echo "  ok      ${idle}% idle"
fi

# The heavyweights worth naming explicitly: these do move a p50 even when their
# average CPU looks modest, because they schedule in bursts.
sims=$(xcrun simctl list devices booted 2>/dev/null | grep -c "Booted" || true)
emus=$(pgrep -f "qemu-system" 2>/dev/null | wc -l | tr -d ' ')
builds=$(pgrep -f "xcodebuild|GradleDaemon|flutter_tools.snapshot" 2>/dev/null | wc -l | tr -d ' ')
if [ "$sims" -gt 0 ] || [ "$emus" -gt 0 ] || [ "$builds" -gt 0 ]; then
  echo "  REFUSE  booted simulators:$sims emulators:$emus builds:$builds — run tool/bench-clean.sh"
  fail=1
else
  echo "  ok      no booted simulator, emulator or active build"
fi

[ "$fail" -eq 1 ] && { echo; echo "Preflight failed. Fix the above, or run tool/bench-clean.sh."; exit 1; }

# ── Build once ───────────────────────────────────────────────────────────────
if [ "$KEEP" = 1 ] && [ -x "$BIN" ]; then
  echo "==> reusing the existing release build"
else
  echo "==> building release (this is the only build; the loop re-executes it)"
  ( cd example && flutter build macos --release \
      --dart-define=NITRO_HTTP_BENCHMARK=1 ) >"$OUT/build.log" 2>&1 \
    || { echo "build failed — see $OUT/build.log"; exit 1; }
fi
[ -x "$BIN" ] || { echo "no benchmark binary at $BIN"; exit 1; }

# ── Run ──────────────────────────────────────────────────────────────────────
echo "==> $RUNS runs into $OUT"
for i in $(seq 1 "$RUNS"); do
  printf '  run %2d/%s ... ' "$i" "$RUNS"
  f=$(printf '%s/run-%02d.txt' "$OUT" "$i")
  "$BIN" 2>&1 | grep "NITRO_BENCH" > "$f"
  if grep -q NITRO_BENCH_END "$f"; then
    p50=$(awk -F'|' '/\| small GET \| nitro_http /{print $7}' "$f" | tr -d ' ')
    echo "ok (small GET p50 $p50)"
  else
    echo "INVALID — no NITRO_BENCH_END"
  fi
  # Let the machine settle so one run's tail does not land in the next one's head.
  sleep 3
done

echo
python3 tool/bench_aggregate.py "$OUT"/run-*.txt
echo
echo "raw runs: $OUT"
