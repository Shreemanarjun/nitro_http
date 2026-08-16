#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — build one dependency slice.
#
#   ./build.sh --platform android --arch arm64-v8a
#   ./build.sh --platform linux   --arch x64
#   ./build.sh --platform ios     --arch arm64
#   ./build.sh --platform ios-sim --arch x86_64
#   ./build.sh --platform macos   --arch arm64 --no-http3
#
# Android and Linux produce a shippable `out/nitro-curl-<slice>.tar.gz` whose
# name matches the slice `src/deps.cmake` computes for that target.
#
# Apple platforms produce only a staged per-architecture install under
# `out/stage/`. There is no per-architecture Apple artefact: the five Apple
# builds are combined into NitroCurl.xcframework.zip and
# nitro-curl-apple-xcframework.tar.gz by merge_apple.sh, which is what
# src/deps.cmake, the podspecs and the SPM manifests consume.
#
# Windows is built by build.ps1 (MSVC + NASM + Ninja), not by this script.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

die() { printf '\nbuild.sh: %s\n\n' "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: build.sh --platform <p> --arch <a> [options]

  --platform   ios | ios-sim | macos | android | linux
  --arch       ios       : arm64
               ios-sim   : arm64 | x86_64
               macos     : arm64 | x86_64
               android   : arm64-v8a | armeabi-v7a | x86_64
               linux     : x64 | arm64
  --out DIR    output root (default: tool/deps/out)
  --no-http3   skip ngtcp2 + nghttp3 and build curl without HTTP/3
               (~0.4 MB / ~9% smaller .so; h3 reported unavailable at runtime)
  --jobs N     parallel build jobs (default: detected core count)
  --clean      delete the build and stage trees for this slice first
EOF
}

PLATFORM=""
ARCH=""
OUT="$HERE/out"
HTTP3="ON"
JOBS=""
CLEAN="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --arch)     ARCH="${2:-}";     shift 2 ;;
    --out)      OUT="${2:-}";      shift 2 ;;
    --jobs)     JOBS="${2:-}";     shift 2 ;;
    --no-http3) HTTP3="OFF";       shift ;;
    --clean)    CLEAN="yes";       shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; die "unknown argument '$1'" ;;
  esac
done

[ -n "$PLATFORM" ] || { usage >&2; die "--platform is required"; }
[ -n "$ARCH" ]     || { usage >&2; die "--arch is required"; }

command -v cmake >/dev/null 2>&1 || die "cmake not found on PATH (need 3.22 or newer)"
command -v git   >/dev/null 2>&1 || die "git not found on PATH (BoringSSL is fetched by commit)"

if [ -z "$JOBS" ]; then
  if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then JOBS="$(sysctl -n hw.ncpu)"
  else JOBS=2
  fi
fi

# ── Resolve platform/arch into a stage name, a slice name and toolchain args ──
# SLICE is empty for Apple: those are merged by merge_apple.sh, never shipped
# per-architecture.
TOOLCHAIN_ARGS=()
SLICE=""

case "$PLATFORM" in
  ios)
    [ "$(uname -s)" = "Darwin" ] || die "--platform ios requires macOS with Xcode"
    [ "$ARCH" = "arm64" ] || die "--platform ios supports --arch arm64 only (got '$ARCH')"
    STAGE_NAME="ios-arm64"
    TOOLCHAIN_ARGS=(
      "-DCMAKE_TOOLCHAIN_FILE=$HERE/toolchains/ios.cmake"
      "-DNH_IOS_SDK=iphoneos"
      "-DCMAKE_OSX_ARCHITECTURES=arm64"
    )
    ;;
  ios-sim)
    [ "$(uname -s)" = "Darwin" ] || die "--platform ios-sim requires macOS with Xcode"
    case "$ARCH" in arm64|x86_64) ;; *) die "--platform ios-sim supports arm64 or x86_64 (got '$ARCH')" ;; esac
    STAGE_NAME="ios-sim-$ARCH"
    TOOLCHAIN_ARGS=(
      "-DCMAKE_TOOLCHAIN_FILE=$HERE/toolchains/ios.cmake"
      "-DNH_IOS_SDK=iphonesimulator"
      "-DCMAKE_OSX_ARCHITECTURES=$ARCH"
    )
    ;;
  macos)
    [ "$(uname -s)" = "Darwin" ] || die "--platform macos requires macOS with Xcode"
    case "$ARCH" in arm64|x86_64) ;; *) die "--platform macos supports arm64 or x86_64 (got '$ARCH')" ;; esac
    STAGE_NAME="macos-$ARCH"
    TOOLCHAIN_ARGS=(
      "-DCMAKE_TOOLCHAIN_FILE=$HERE/toolchains/macos.cmake"
      "-DCMAKE_OSX_ARCHITECTURES=$ARCH"
    )
    ;;
  android)
    case "$ARCH" in
      arm64-v8a|armeabi-v7a|x86_64) ;;
      *) die "--platform android supports arm64-v8a, armeabi-v7a or x86_64 (got '$ARCH')" ;;
    esac
    NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
    [ -n "$NDK" ] || die \
"ANDROID_NDK_HOME is not set.

  An Android slice cannot be built without the NDK (r27 or newer).

    export ANDROID_NDK_HOME=\$HOME/Library/Android/sdk/ndk/27.2.12479018   # macOS
    export ANDROID_NDK_HOME=\$HOME/Android/Sdk/ndk/27.2.12479018            # Linux

  ANDROID_NDK_ROOT and ANDROID_NDK are accepted as fallbacks."
    [ -f "$NDK/build/cmake/android.toolchain.cmake" ] || die \
      "ANDROID_NDK_HOME='$NDK' is not an NDK install (no build/cmake/android.toolchain.cmake)"
    STAGE_NAME="android-$ARCH"
    SLICE="android-$ARCH"
    TOOLCHAIN_ARGS=(
      "-DCMAKE_TOOLCHAIN_FILE=$HERE/toolchains/android.cmake"
      "-DANDROID_NDK=$NDK"
      "-DANDROID_ABI=$ARCH"
    )
    ;;
  linux)
    case "$ARCH" in
      x64|x86_64)     SLICE="linux-x64";   HOST_EXPECT="x86_64" ;;
      arm64|aarch64)  SLICE="linux-arm64"; HOST_EXPECT="aarch64" ;;
      *) die "--platform linux supports x64 or arm64 (got '$ARCH')" ;;
    esac
    HOST_ARCH="$(uname -m)"
    # No Linux cross toolchain is provided: CI runs each Linux slice on a runner
    # of that architecture. Cross-compiling here would silently produce host
    # binaries under the wrong slice name.
    case "$HOST_ARCH" in
      "$HOST_EXPECT") ;;
      x86_64|amd64) [ "$HOST_EXPECT" = "x86_64" ] || die "cannot build $SLICE on a $HOST_ARCH host" ;;
      aarch64|arm64) [ "$HOST_EXPECT" = "aarch64" ] || die "cannot build $SLICE on a $HOST_ARCH host" ;;
      *) die "unsupported Linux host architecture '$HOST_ARCH'" ;;
    esac
    STAGE_NAME="$SLICE"
    ;;
  *)
    usage >&2
    die "unknown --platform '$PLATFORM'"
    ;;
esac

BUILD_DIR="$OUT/build/$STAGE_NAME"
STAGE_DIR="$OUT/stage/$STAGE_NAME"

if [ "$CLEAN" = "yes" ]; then
  rm -rf "$BUILD_DIR" "$STAGE_DIR"
fi
mkdir -p "$BUILD_DIR" "$STAGE_DIR" "$OUT"

# Ninja rebuilds the eight sub-projects far faster and, on Windows, is the only
# generator that assembles BoringSSL's .asm at all. Fall back to Make so a bare
# Linux box still works.
if command -v ninja >/dev/null 2>&1; then
  GENERATOR="Ninja"
else
  GENERATOR="Unix Makefiles"
fi

echo "==> nitro_http deps: $STAGE_NAME (http3=$HTTP3, generator=$GENERATOR, jobs=$JOBS)"

# ── Cross-slice cache ────────────────────────────────────────────────────────
# Sources do not vary by architecture, only builds do. Priming the BoringSSL
# mirror once turns a ~62 MB clone per slice into a local object copy.
CACHE_DIR="${NITRO_HTTP_DEPS_CACHE:-$OUT/cache}"
mkdir -p "$CACHE_DIR"

# Read from deps/versions.cmake rather than duplicated: a second copy of a
# 40-character hash is a silent-drift bug waiting to happen.
BORINGSSL_COMMIT=$(sed -n \
  's/^set(NH_BORINGSSL_COMMIT[[:space:]]*\([0-9a-f]\{40\}\).*/\1/p' \
  "$HERE/../../deps/versions.cmake" | head -1)
[ -n "$BORINGSSL_COMMIT" ] || die \
  "could not read NH_BORINGSSL_COMMIT from deps/versions.cmake"

BORINGSSL_MIRROR="$CACHE_DIR/boringssl.git"

# A critical section: build-curl.sh runs slices concurrently and they share this
# directory, so two `git init`/fetch calls collide without a lock. Reading FROM
# the mirror afterwards needs none. mkdir is the portable atomic primitive; the
# EXIT trap releases it even when `die` fires inside.
NH_LOCK="$CACHE_DIR/.boringssl.lock"
waited=0
while ! mkdir "$NH_LOCK" 2>/dev/null; do
  waited=$((waited + 1))
  [ "$waited" -gt 900 ] && die \
    "timed out waiting for $NH_LOCK — delete it if a previous build was killed"
  sleep 1
done
trap 'rmdir "$NH_LOCK" 2>/dev/null || true' EXIT

[ -d "$BORINGSSL_MIRROR" ] || git init --bare --quiet "$BORINGSSL_MIRROR"
# Cheap on every slice after the first: the object is already present, so this
# is a local ref check rather than a transfer.
if ! git -C "$BORINGSSL_MIRROR" cat-file -e "${BORINGSSL_COMMIT}^{commit}" 2>/dev/null; then
  echo "==> priming BoringSSL mirror once for every slice (${BORINGSSL_COMMIT:0:12})"
  git -C "$BORINGSSL_MIRROR" fetch --quiet --depth 1 \
    https://github.com/google/boringssl.git "$BORINGSSL_COMMIT" \
    || die "could not fetch BoringSSL $BORINGSSL_COMMIT into $BORINGSSL_MIRROR"
fi

rmdir "$NH_LOCK" 2>/dev/null || true
trap - EXIT

cmake -S "$HERE" -B "$BUILD_DIR" -G "$GENERATOR" \
  "-DCMAKE_INSTALL_PREFIX=$STAGE_DIR" \
  "-DNITRO_HTTP_ENABLE_HTTP3=$HTTP3" \
  "-DNH_CACHE_DIR=$CACHE_DIR" \
  "${TOOLCHAIN_ARGS[@]}"

cmake --build "$BUILD_DIR" --parallel "$JOBS"

# ── Sanity-check the staged tree before anyone packages it ───────────────────
[ -f "$STAGE_DIR/include/curl/curl.h" ] || die \
  "build finished but $STAGE_DIR/include/curl/curl.h is missing — the slice is unusable"
[ -f "$STAGE_DIR/manifest.json" ] || die \
  "build finished but $STAGE_DIR/manifest.json is missing"
if [ -z "$(ls -A "$STAGE_DIR/lib" 2>/dev/null || true)" ]; then
  die "build finished but $STAGE_DIR/lib is empty"
fi

if [ -z "$SLICE" ]; then
  echo "==> staged $STAGE_NAME at $STAGE_DIR"
  echo "    Apple slices ship as one xcframework; run:"
  echo "      $HERE/merge_apple.sh --stage $OUT/stage --out $OUT"
  exit 0
fi

TARBALL="$OUT/nitro-curl-$SLICE.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$STAGE_DIR" lib include manifest.json

# An empty or tiny archive means the tar silently skipped something; catching it
# here beats a consumer discovering it via a link error three CI jobs later.
SIZE="$(wc -c < "$TARBALL" | tr -d ' ')"
[ "$SIZE" -gt 100000 ] || die "produced $TARBALL but it is only $SIZE bytes — refusing to publish"

echo "==> $TARBALL ($SIZE bytes)"
