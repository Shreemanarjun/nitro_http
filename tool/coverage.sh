#!/usr/bin/env bash
#
# Runs the Dart unit suite with coverage and reports it against a floor.
#
# Generated code is excluded. `lib/src/nitro_http.g.dart` is nitrogen's output:
# it is 887 lines of FFI trampolines whose uncovered half is the paths that need
# a loaded dynamic library (streams, native-async wrappers, every WebSocket
# entry point). Counting it would mean either a permanently capped number or
# writing tests against generated code, and neither says anything about whether
# this package is correct. `nitrogen generate` is what guarantees that file.
#
#   tool/coverage.sh            # report, fail under the floor
#   tool/coverage.sh 95         # report, fail under 95%
#   tool/coverage.sh --html     # also write coverage/html/index.html
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FLOOR=92
WANT_HTML=0
for arg in "$@"; do
  case "$arg" in
    --html) WANT_HTML=1 ;;
    *[!0-9]*) echo "usage: tool/coverage.sh [FLOOR] [--html]" >&2; exit 2 ;;
    *) FLOOR="$arg" ;;
  esac
done

echo "==> flutter test --coverage"
flutter test --coverage

# `lcov --remove` needs lcov installed; the Python fallback keeps this working
# on a bare CI image. Both write the same filtered file.
FILTERED=coverage/lcov-filtered.info
if command -v lcov >/dev/null 2>&1; then
  lcov --quiet --remove coverage/lcov.info \
    '*/nitro_http.g.dart' \
    --output-file "$FILTERED" \
    --ignore-errors unused
else
  python3 - "$FILTERED" <<'PY'
import sys
out = sys.argv[1]
keep, record, skip = [], [], False
for line in open('coverage/lcov.info'):
    if line.startswith('SF:'):
        record, skip = [line], line.rstrip().endswith('nitro_http.g.dart')
    else:
        record.append(line)
        if line.strip() == 'end_of_record':
            if not skip:
                keep.extend(record)
            record = []
open(out, 'w').writelines(keep)
PY
fi

python3 - "$FILTERED" "$FLOOR" <<'PY'
import sys

path, floor = sys.argv[1], float(sys.argv[2])
files, cur, found, hit = [], None, 0, 0
for line in open(path):
    line = line.rstrip('\n')
    if line.startswith('SF:'):
        cur, found, hit = line[3:], 0, 0
    elif line.startswith('LF:'):
        found = int(line[3:])
    elif line.startswith('LH:'):
        hit = int(line[3:])
    elif line == 'end_of_record' and cur:
        files.append((cur, found, hit))
        cur = None

total_found = sum(f for _, f, _ in files)
total_hit = sum(h for _, _, h in files)
pct = 100 * total_hit / total_found if total_found else 100.0

incomplete = sorted(
    ((f, fo, hi) for f, fo, hi in files if hi < fo),
    key=lambda x: x[2] / x[1] if x[1] else 1,
)
if incomplete:
    print('\nBelow 100%:')
    for f, fo, hi in incomplete:
        name = f.split('lib/', 1)[-1]
        print(f'  {100 * hi / fo:6.2f}%  {hi:4d}/{fo:4d}  {name}  (missing {fo - hi})')

print(f'\nTOTAL (hand-written): {total_hit}/{total_found} = {pct:.2f}%')
if pct + 1e-9 < floor:
    print(f'FAIL: below the {floor:.0f}% floor')
    sys.exit(1)
print(f'OK: at or above the {floor:.0f}% floor')
PY

if [ "$WANT_HTML" = 1 ]; then
  command -v genhtml >/dev/null 2>&1 \
    && genhtml --quiet "$FILTERED" -o coverage/html \
    && echo "==> coverage/html/index.html" \
    || echo "genhtml not installed; skipping HTML" >&2
fi
