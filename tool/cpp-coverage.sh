#!/usr/bin/env bash
#
# Line coverage for the C++ engine.
#
#   tool/cpp-coverage.sh              # report
#   tool/cpp-coverage.sh 60           # report, fail under 60%
#   tool/cpp-coverage.sh --html       # also write build/cppcov/html/index.html
#
# WHY THIS EXISTS. `tool/coverage.sh` measures the DART side — about 2 200 lines
# of glue. The engine is ~11 000 lines of C++ doing the actual HTTP work, and it
# had 245 passing tests and no coverage number at all, so "the engine is tested"
# was an assertion nobody could check. A pass count says how much was run, never
# how much was missed.
#
# Uses clang's source-based coverage (-fprofile-instr-generate
# -fcoverage-mapping) because it is what the toolchain already ships; gcov would
# need a second toolchain on macOS.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FLOOR=""
WANT_HTML=0
for arg in "$@"; do
  case "$arg" in
    --html) WANT_HTML=1 ;;
    *[!0-9]*) echo "usage: tool/cpp-coverage.sh [FLOOR] [--html]" >&2; exit 2 ;;
    *) FLOOR="$arg" ;;
  esac
done

# Prefer the toolchain's own llvm tools: a Homebrew llvm-cov and an Xcode clang
# disagree about the profile format and fail with an unhelpful version error.
# Debian/Ubuntu ships VERSIONED names only (llvm-profdata-18), so plain-name
# lookup finds nothing there and the versioned fallback is not optional.
find_llvm() {
  local base="$1" found
  found="$(xcrun -f "$base" 2>/dev/null)" && [ -x "$found" ] && { echo "$found"; return; }
  found="$(command -v "$base" 2>/dev/null)" && { echo "$found"; return; }
  for v in 21 20 19 18 17 16 15 14; do
    found="$(command -v "$base-$v" 2>/dev/null)" && { echo "$found"; return; }
  done
  return 1
}
PROFDATA="$(find_llvm llvm-profdata)" || {
  echo "llvm-profdata not found — install the LLVM tools" >&2; exit 1; }
COV="$(find_llvm llvm-cov)" || {
  echo "llvm-cov not found — install the LLVM tools" >&2; exit 1; }

BUILD=build/cppcov
echo "==> configuring instrumented build"
cmake -S src -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DNITRO_HTTP_BUILD_TESTS=ON \
  -DNITRO_HTTP_TESTS_COVERAGE=ON >/dev/null || exit 1

echo "==> building"
cmake --build "$BUILD" --parallel 8 >/dev/null || exit 1

echo "==> running the suite"
rm -rf "$BUILD/profraw" && mkdir -p "$BUILD/profraw"
# %p keeps one raw profile per process; the exit-path test deliberately dies at
# process exit, so a single fixed filename would be overwritten or truncated.
LLVM_PROFILE_FILE="$PWD/$BUILD/profraw/%p.profraw" \
  ctest --test-dir "$BUILD" --output-on-failure >/dev/null
rc=$?

BINS=()
for b in "$BUILD"/nitro_http_tests/nitro_http_engine_tests \
         "$BUILD"/nitro_http_tests/nitro_http_exit_path_test; do
  [ -x "$b" ] && BINS+=("-object" "$b")
done
[ "${#BINS[@]}" -gt 0 ] || { echo "no instrumented binaries found in $BUILD" >&2; exit 1; }

# `llvm-cov report` treats trailing arguments as OBJECT files, not as a source
# filter — passing src/engine fails with "Is a directory" and passing the .cpp
# files fails with "not a valid object file". Narrowing to the engine therefore
# has to be done by excluding everything else.
RX='(/test/|_test\.cpp|googletest|/usr/|/_deps/|third_party|/src/native/|\.inc$|/generated/|/include/curl/)'

"$PROFDATA" merge -sparse "$BUILD"/profraw/*.profraw -o "$BUILD/merged.profdata" || exit 1

echo
echo "=============================================================================="
echo "C++ ENGINE COVERAGE — src/engine only. Test sources, GoogleTest and the"
echo "vendored stack are excluded: covering a test file measures nothing."
echo "=============================================================================="
"$COV" report "${BINS[@]}" \
  -instr-profile="$BUILD/merged.profdata" \
  -ignore-filename-regex="$RX" 2>/dev/null | tail -40

if [ "$WANT_HTML" = 1 ]; then
  "$COV" show "${BINS[@]}" \
    -instr-profile="$BUILD/merged.profdata" \
    -ignore-filename-regex="$RX" \
    -format=html -output-dir="$BUILD/html" >/dev/null 2>&1
  echo
  echo "html: $BUILD/html/index.html"
fi

if [ -n "$FLOOR" ]; then
  TOTAL=$("$COV" report "${BINS[@]}" \
    -instr-profile="$BUILD/merged.profdata" \
    -ignore-filename-regex="$RX" 2>/dev/null | awk '/^TOTAL/{gsub("%","",$10); print int($10)}')   # $10 = LINE coverage
  echo
  if [ -n "$TOTAL" ] && [ "$TOTAL" -lt "$FLOOR" ]; then
    echo "FAIL: line coverage ${TOTAL}% is below the ${FLOOR}% floor"
    exit 1
  fi
  echo "OK: line coverage ${TOTAL}% meets the ${FLOOR}% floor"
fi

exit "$rc"
