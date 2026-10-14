#!/usr/bin/env bash
#
# Run the macOS comparison benchmark and aggregate the result.
#
#   tool/bench-macos.sh                # 10 runs (1 discarded as warm-up)
#   tool/bench-macos.sh 20             # 20 runs
#   tool/bench-macos.sh 10 --keep      # keep an existing build, skip rebuilding
#   tool/bench-macos.sh 6 --adaptive   # 6 runs, then keep going until the
#                                      # controls stop drifting (cap --max, default 18)
#
# Why a loop and not one run: a single run of this suite has flipped the fastest
# client in four of five scenarios. Ten runs is the point where the aggregator
# can separate a real gap from this laptop, and it costs about five minutes.
# --adaptive stops early when the machine is already quiet and runs longer only
# for the scenarios that are still noisy, rather than paying a fixed count every
# time.
#
# Why the binary is executed directly rather than through `flutter run`: the
# tool never exits after the app calls exit(), so a loop built on it deadlocks
# on the first iteration. Build once, exec many.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# ── Arguments ──────────────────────────────────────────────────────────────
# First bare number is the run count (the minimum, under --adaptive). Flags may
# appear in any order.
RUNS=10
KEEP=0
ADAPTIVE=0
MAX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --adaptive) ADAPTIVE=1 ;;
    --max) shift; MAX="${1:-0}" ;;
    ''|*[!0-9]*) echo "usage: $0 [runs] [--keep] [--adaptive] [--max N]" >&2; exit 2 ;;
    *) RUNS="$1" ;;
  esac
  shift
done
[ "$MAX" -eq 0 ] && MAX=$((RUNS * 3))
[ "$MAX" -lt "$RUNS" ] && MAX="$RUNS"

APP="example/build/macos/Build/Products/Release/nitro_http_example.app"
BIN="$APP/Contents/MacOS/nitro_http_example"
OUT="build/bench/macos-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# How busy the machine is RIGHT NOW, as idle percent.
#
# Two traps, both of which produced a wrong answer before this existed. Matching
# on process names cries wolf: a Mac with Xcode installed always has
# CoreSimulator helpers and `xcdevice observe` alive, and they are idle. And
# `ps -o %cpu` is a LIFETIME average on macOS, so anything long-lived that was
# busy an hour ago still reads hot while doing nothing. `top -l 2` samples twice
# and discards the first; the second sample is a true interval.
sample_idle() {
  local sample
  sample=$(top -l 2 -n 0 2>/dev/null | awk '/^CPU usage/{s++} s==2')
  printf '%s\n' "$sample" |
    awk '/^CPU usage/{for (i = 1; i <= NF; i++) if ($i == "idle") {gsub(/%/, "", $(i-1)); print $(i-1); exit}}'
}
current_load() { uptime | sed 's/.*load averages*: *//' | awk '{print $1}'; }

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
load=$(current_load)
# One busy core out of eight is tolerable; half the machine is not.
if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c/2)}'; then
  echo "  REFUSE  load $load on $cores cores — something else is running"; fail=1
else
  echo "  ok      load $load on $cores cores"
fi

idle=$(sample_idle)
if [ -z "$idle" ]; then
  echo "  ok      could not sample CPU (top unavailable) — proceeding"
elif awk -v i="$idle" 'BEGIN{exit !(i < 70)}'; then
  echo "  REFUSE  only ${idle}% idle"; fail=1
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

# ── Harden the machine for the run (best effort) ─────────────────────────────
# Spotlight reindexing (mds_stores) is the single biggest bursty-noise source on
# a dev Mac, and it does not show up in the one-shot preflight because it starts
# when the filesystem changes mid-run. Pause it for the duration and restore it
# after — but only if we can do so without a password prompt, because a
# benchmark that blocks on sudo is worse than one that runs with Spotlight on.
SPOTLIGHT_PAUSED=0
restore_spotlight() {
  [ "$SPOTLIGHT_PAUSED" = 1 ] && sudo -n mdutil -a -i on >/dev/null 2>&1 && echo "  restored Spotlight indexing"
  SPOTLIGHT_PAUSED=0
}
trap restore_spotlight EXIT INT TERM
if sudo -n true 2>/dev/null; then
  if sudo -n mdutil -a -i off >/dev/null 2>&1; then
    SPOTLIGHT_PAUSED=1
    echo "  ok      Spotlight indexing paused for the run"
  fi
else
  if mdutil -s / 2>/dev/null | grep -qi "indexing enabled"; then
    echo "  note    Spotlight indexing is ON; no passwordless sudo to pause it."
    echo "          For the quietest run: sudo mdutil -a -i off   (re-enable with -i on)"
  fi
fi
# CPU affinity: macOS exposes no P-core pin without a private entitlement, and a
# foreground default-QoS process is already scheduled onto the performance
# cores — so there is nothing to force here. `taskpolicy` only ever DEMOTES, so
# using it would make things worse. Left as a note so nobody "adds pinning".

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
if [ "$ADAPTIVE" = 1 ]; then
  echo "==> adaptive: $RUNS..$MAX runs into $OUT, stopping once controls are quiet"
else
  echo "==> $RUNS runs into $OUT"
fi
i=0
while :; do
  i=$((i + 1))
  printf '  run %2d ... ' "$i"
  f=$(printf '%s/run-%02d.txt' "$OUT" "$i")
  "$BIN" 2>&1 | grep "NITRO_BENCH" > "$f"
  if grep -q NITRO_BENCH_END "$f"; then
    p50=$(awk -F'|' '/\| small GET \| nitro_http /{print $7}' "$f" | tr -d ' ')
    status="ok (small GET p50 $p50)"
  else
    status="INVALID — no NITRO_BENCH_END"
  fi
  # Stamp the machine state this run actually executed under, so the aggregator
  # can drop a run that drifted rather than only flagging the whole scenario.
  # The sample is a ~2s interval, which doubles as the settle between runs so one
  # run's tail does not land in the next one's head.
  run_idle=$(sample_idle)
  printf '# NITRO_BENCH_ENV idle=%s load=%s\n' "${run_idle:-nan}" "$(current_load)" >> "$f"
  echo "$status  [idle ${run_idle:-?}%]"

  if [ "$i" -ge "$RUNS" ]; then
    if [ "$ADAPTIVE" != 1 ]; then
      break
    fi
    verdict=$(python3 tool/bench_aggregate.py "$OUT"/run-*.txt --stable-check 2>/dev/null | tail -1)
    echo "     stability after $i runs: $verdict"
    case "$verdict" in STABLE*) break ;; esac
    if [ "$i" -ge "$MAX" ]; then
      echo "     reached --max $MAX; stopping with: $verdict"
      break
    fi
  fi
done

echo
# --min-idle drops any run the ENV stamp shows executed below 70% idle: the
# mid-session spike the one-shot preflight could not see.
python3 tool/bench_aggregate.py "$OUT"/run-*.txt --min-idle 70
echo
echo "raw runs: $OUT"
