#!/usr/bin/env bash
#
# Run the comparison benchmark N times on a connected Android device.
#
#   tool/bench-android.sh            # 10 runs (1 discarded as warm-up)
#   tool/bench-android.sh 20
#   tool/bench-android.sh 10 --keep  # reuse the installed APK, skip the build
#
# Everything here that looks paranoid is a bug this project already paid for.
#
# THERMALS ARE THE WHOLE GAME. Two measurement sets taken minutes apart differed
# by 11-60% PER CLIENT purely because the phone was warm, which flipped the
# fastest client in rows that were otherwise stable. A phone benchmark without a
# thermal gate is not a slow benchmark, it is a wrong one. So this waits for the
# CPU zones to come down before every run, not just the first, and records the
# temperature next to each result so a suspicious set can be re-read afterwards.
#
# `dumpsys thermalservice` is NOT usable for this: it reports a cached
# throttling status that stays stale long after the die has cooled. The
# /sys/class/thermal zones are the live reading. Only the `cpu*` zones are
# gated — this SoC's PMIC zone sits high permanently and would block forever.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNS="${1:-10}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1
case "$RUNS" in ''|*[!0-9]*) echo "usage: $0 [runs] [--keep]" >&2; exit 2 ;; esac

APP_ID="dev.shreeman.nitro_http_example"
GATE_MC=42000          # millicelsius; ~42 C, the point past which sets stop agreeing
COOL_TIMEOUT=600       # seconds to wait for the phone to come down
OUT="build/bench/android-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

hottest_cpu() {
  # Max over cpu* zones only, in millicelsius.
  adb shell 'for z in /sys/class/thermal/thermal_zone*; do
      t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
      case "$t" in cpu*) echo "$v";; esac
    done' 2>/dev/null | tr -d '\r' | sort -n | tail -1
}

cool_down() {
  local waited=0 t
  t=$(hottest_cpu)
  [ -z "$t" ] && { echo "  (no thermal zones readable — proceeding ungated)"; return 0; }
  while [ "$t" -gt "$GATE_MC" ] 2>/dev/null; do
    if [ "$waited" -ge "$COOL_TIMEOUT" ]; then
      echo "  REFUSE  still $((t/1000)) C after ${waited}s (gate $((GATE_MC/1000)) C)"
      return 1
    fi
    printf '\r  cooling: %d C, waiting for %d C ... %ds' "$((t/1000))" "$((GATE_MC/1000))" "$waited"
    sleep 15; waited=$((waited+15)); t=$(hottest_cpu)
  done
  printf '\r  ok      %d C (gate %d C)%-24s\n' "$((t/1000))" "$((GATE_MC/1000))" ""
  return 0
}

# ── Preflight ────────────────────────────────────────────────────────────────
fail=0
devices=$(adb devices | grep -cw "device" || true)
if [ "$devices" -ne 1 ]; then
  echo "  REFUSE  need exactly one device attached, found $devices"; fail=1
else
  echo "  ok      $(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r') on Android $(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
fi

# An emulator's timings are worthless here: a previous "1.75-2.1x download
# regression" came from one and real hardware refuted it entirely.
if adb shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r' | grep -q 1; then
  echo "  REFUSE  this is an emulator"; fail=1
fi

level=$(adb shell dumpsys battery 2>/dev/null | awk -F': ' '/  level/{print $2}' | tr -d '\r')
if [ -n "$level" ] && [ "$level" -lt 30 ] 2>/dev/null; then
  echo "  REFUSE  battery $level% — Android throttles hard when low"; fail=1
else
  echo "  ok      battery ${level:-?}%"
fi

# A secured lock screen is the quietest way to lose a whole set. The launch
# intent is delivered and `monkey` cheerfully reports "Events injected: 1", but
# the activity never comes to the foreground behind the keyguard, so every run
# logs nothing at all and the set ends 10-for-10 INVALID with no clue why.
# `wm dismiss-keyguard` clears an insecure keyguard only; a PIN or pattern needs
# a human, so ask for one instead of burning half an hour discovering it.
adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb shell wm dismiss-keyguard >/dev/null 2>&1
sleep 1
if adb shell dumpsys window 2>/dev/null | grep -q "isKeyguardShowing=true"; then
  echo "  REFUSE  the screen is locked — unlock the phone and leave it unlocked"
  fail=1
else
  echo "  ok      screen unlocked"
fi

[ "$fail" -eq 1 ] && { echo; echo "Preflight failed."; exit 1; }

# ── Build and install once ───────────────────────────────────────────────────
APK="example/build/app/outputs/flutter-apk/app-release.apk"
if [ "$KEEP" = 1 ] && [ -f "$APK" ]; then
  echo "==> reusing the existing APK"
else
  echo "==> building release APK (arm64 only, matching the vendored slice)"
  ( cd example && flutter build apk --release \
      --target-platform android-arm64 \
      --dart-define=NITRO_HTTP_BENCHMARK=1 ) >"$OUT/build.log" 2>&1 \
    || { echo "build failed — see $OUT/build.log"; exit 1; }
fi
# `-r` rather than a clean install: a stale package-manager entry on this device
# has previously produced "Activity does not exist" for an app that was present.
adb install -r "$APK" >"$OUT/install.log" 2>&1 || { echo "install failed — see $OUT/install.log"; exit 1; }
echo "==> installed $APP_ID"

# Charging warms the die, and the die is the thing being controlled for. Ask the
# phone to ignore the cable; it re-attaches by itself when the run ends.
#
# This has a side effect that cost a whole 10-run set: "unplugged" also cancels
# stay-on-while-plugged-in, so the screen starts obeying its normal timeout. Ten
# minutes in — around run 6 — the display slept, the app stopped being
# foreground, and every run after that logged NITRO_BENCH_BEGIN and then hung
# forever. So the screen is pinned open explicitly rather than relying on the
# cable, and both settings are restored on the way out.
ORIG_TIMEOUT=$(adb shell settings get system screen_off_timeout 2>/dev/null | tr -d '\r')
adb shell dumpsys battery unplug >/dev/null 2>&1 || true
adb shell settings put system screen_off_timeout 1800000 >/dev/null 2>&1 || true
restore_device() {
  adb shell dumpsys battery reset >/dev/null 2>&1 || true
  case "$ORIG_TIMEOUT" in
    ''|*[!0-9]*) ;;
    *) adb shell settings put system screen_off_timeout "$ORIG_TIMEOUT" >/dev/null 2>&1 || true ;;
  esac
}
trap restore_device EXIT

echo "==> $RUNS runs into $OUT"
for i in $(seq 1 "$RUNS"); do
  printf '  run %2d/%s\n' "$i" "$RUNS"
  cool_down || { echo "  giving up: device will not cool"; break; }
  temp=$(hottest_cpu)

  # Wake and unlock before launching: a sleeping screen is what broke the
  # second half of the first full set.
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
  adb shell wm dismiss-keyguard >/dev/null 2>&1

  adb logcat -c >/dev/null 2>&1
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1
  adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

  f=$(printf '%s/run-%02d.txt' "$OUT" "$i")
  # Poll rather than stream: `adb logcat` has no clean "stop at this line".
  for _ in $(seq 1 120); do
    adb logcat -d -s flutter:I 2>/dev/null | grep "NITRO_BENCH" > "$f"
    grep -q NITRO_BENCH_END "$f" && break
    sleep 2
  done
  echo "# device cpu ${temp} mC at start" >> "$f"

  if grep -q NITRO_BENCH_END "$f"; then
    p50=$(awk -F'|' '/\| small GET \| nitro_http /{print $7}' "$f" | tr -d ' ')
    echo "    ok  $((temp/1000)) C  small GET p50 $p50"
  else
    began=$(grep -c NITRO_BENCH_BEGIN "$f" || true)
    if [ "$began" -gt 0 ]; then
      echo "    INVALID — started but never finished (hung); screen state?"
    else
      echo "    INVALID — never started; check the launch"
    fi
  fi
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1
done

echo
python3 tool/bench_aggregate.py "$OUT"/run-*.txt
echo
echo "raw runs: $OUT"
