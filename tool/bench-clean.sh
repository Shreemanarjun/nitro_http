#!/usr/bin/env bash
#
# Puts the machine into a defensible state for benchmarking, then reports what it
# could not fix.
#
# Benchmark numbers are only comparable against a quiet machine, and this project
# has already been burned twice by ignoring that: an Android emulator reported a
# 1.75-2.1x download regression that real hardware refuted entirely, and repeating
# the macOS suite minutes apart flipped the fastest client in four of five rows
# because builds were running alongside it.
#
#   tool/bench-clean.sh          # tidy up, then report
#   tool/bench-clean.sh --check  # report only, change nothing
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say() { printf '%s\n' "$*"; }
kill_match() {
  local label="$1" pattern="$2"
  local pids
  pids=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' ' ')
  [ -z "${pids// /}" ] && return 0
  if [ "$CHECK_ONLY" = 1 ]; then
    say "  would stop $label (pids:$pids)"
  else
    say "  stopping $label (pids:$pids)"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
  fi
}

say "==> simulators and emulators"
# An iOS simulator or Android emulator idling still schedules work and holds
# memory; on a laptop that is enough to move a p50.
if command -v xcrun >/dev/null 2>&1; then
  booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c "Booted" || true)
  if [ "${booted:-0}" -gt 0 ]; then
    if [ "$CHECK_ONLY" = 1 ]; then
      say "  would shut down $booted booted iOS simulator(s)"
    else
      say "  shutting down $booted booted iOS simulator(s)"
      xcrun simctl shutdown all >/dev/null 2>&1 || true
    fi
  else
    say "  no booted iOS simulators"
  fi
fi
kill_match "Android emulator" "qemu-system|emulator64|/emulator/emulator"

say "==> stale app instances"
# A previous benchmark app still running holds the loopback port and competes for
# CPU. This is why a five-run loop produced one usable run: each new instance
# started while the last was still alive.
kill_match "nitro_http_example" "nitro_http_example"

say "==> build and tooling processes"
kill_match "Gradle daemon" "GradleDaemon"
kill_match "Dart analysis server" "dart .*analysis_server"

say "==> machine state"
if command -v uptime >/dev/null 2>&1; then
  say "  load:$(uptime | sed 's/.*load averages*://')"
fi
if command -v pmset >/dev/null 2>&1; then
  src=$(pmset -g ps 2>/dev/null | head -1)
  case "$src" in
    *Battery*) say "  POWER: on battery — plug in. macOS throttles aggressively and the numbers will not compare." ;;
    *) say "  power: AC" ;;
  esac
fi
if command -v osascript >/dev/null 2>&1 && [ "$CHECK_ONLY" = 0 ]; then
  # Thermal pressure moves a benchmark more than most code changes do.
  therm=$(pmset -g therm 2>/dev/null | grep -i "CPU_Speed_Limit" | tail -1)
  [ -n "$therm" ] && say "  thermal: $therm"
fi

say ""
say "Let the machine settle for a few seconds, then run the benchmark."
say "Compare medians across at least three complete runs — a single run has"
say "flipped the winner in four of five scenarios on this project."
