#!/usr/bin/env bash
#
# Compile OkHttpBench.kt into a dex jar runnable on-device via `app_process`
# (no Gradle, no app). Fetches the two runtime deps (pinned) from Maven Central
# into a cache, compiles with kotlinc, and dexes with d8 from the Android SDK
# build-tools. Prints the absolute path to benchdex.jar on the last line.
#
#   tool/bench_native/android/build-dex.sh
#
# Needs: kotlinc on PATH, curl, and an Android SDK (ANDROID_SDK_ROOT / ANDROID_HOME,
# default ~/Library/Android/sdk) with any build-tools installed (for d8).
set -euo pipefail

# Pinned so a rebuilt dex is byte-reproducible and a silent upstream bump can't
# change the baseline. okhttp 4.12.0 pairs with okio 3.6.0.
OKHTTP_VER=4.12.0
OKIO_VER=3.6.0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${BENCH_NATIVE_CACHE:-$(cd "$HERE/../../.." && pwd)/build/bench/native-cache}"
mkdir -p "$CACHE"

fetch() { # url dest
  [ -s "$2" ] || { echo "  fetch $(basename "$2")" >&2; curl -fsSL "$1" -o "$2"; }
}
fetch "https://repo1.maven.org/maven2/com/squareup/okhttp3/okhttp/$OKHTTP_VER/okhttp-$OKHTTP_VER.jar" "$CACHE/okhttp.jar"
fetch "https://repo1.maven.org/maven2/com/squareup/okio/okio-jvm/$OKIO_VER/okio-jvm-$OKIO_VER.jar" "$CACHE/okio.jar"

command -v kotlinc >/dev/null 2>&1 || { echo "kotlinc not on PATH (brew install kotlin)" >&2; exit 1; }

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
D8="$(ls "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -1 || true)"
[ -x "$D8" ] || { echo "d8 not found under $SDK/build-tools — install Android build-tools" >&2; exit 1; }

echo "  kotlinc -> bench.jar" >&2
kotlinc "$HERE/OkHttpBench.kt" -cp "$CACHE/okhttp.jar:$CACHE/okio.jar" \
  -include-runtime -d "$CACHE/bench.jar" >&2

echo "  d8 -> benchdex.jar" >&2
rm -rf "$CACHE/dexout"; mkdir -p "$CACHE/dexout"
"$D8" --min-api 26 --output "$CACHE/dexout" \
  "$CACHE/bench.jar" "$CACHE/okhttp.jar" "$CACHE/okio.jar" >&2
rm -f "$CACHE/benchdex.jar"
( cd "$CACHE/dexout" && zip -q "$CACHE/benchdex.jar" classes*.dex )

echo "$CACHE/benchdex.jar"
