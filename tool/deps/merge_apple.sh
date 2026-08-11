#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — fold the five per-architecture Apple builds into shippable
# artefacts.
#
# Input  (produced by build.sh, one configure per architecture because
#         BoringSSL refuses to build fat binaries):
#
#   <stage>/ios-arm64        <stage>/ios-sim-arm64   <stage>/ios-sim-x86_64
#   <stage>/macos-arm64      <stage>/macos-x86_64
#
# Output (both are needed — they serve different consumers):
#
#   NitroCurl.xcframework.zip             CocoaPods `vendored_frameworks` and
#                                         SwiftPM `.binaryTarget`. Contains one
#                                         merged libNitroCurl.a per platform
#                                         slice plus the headers.
#   nitro-curl-apple-xcframework.tar.gz   the `apple-xcframework` slice that
#                                         src/deps.cmake downloads when CMake
#                                         drives an Apple build (the C++ test
#                                         suite, and macOS desktop builds that
#                                         bypass CocoaPods). Keeps the archives
#                                         separate because deps.cmake resolves
#                                         them one find_library at a time.
#
# Per xcframework slice the component archives are folded together with
# `libtool -static`; the two-architecture slices are then produced with
# `lipo -create`.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

die() { printf '\nmerge_apple.sh: %s\n\n' "$1" >&2; exit 1; }

STAGE="$HERE/out/stage"
OUT="$HERE/out"

while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="${2:-}"; shift 2 ;;
    --out)   OUT="${2:-}";   shift 2 ;;
    -h|--help)
      cat <<'EOF'
usage: merge_apple.sh [--stage DIR] [--out DIR]

  --stage  directory holding the per-architecture installs
           (default: tool/deps/out/stage)
  --out    where to write the artefacts (default: tool/deps/out)
EOF
      exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "Apple artefacts can only be produced on macOS"
command -v libtool    >/dev/null 2>&1 || die "libtool not found (install the Xcode command line tools)"
command -v lipo       >/dev/null 2>&1 || die "lipo not found (install the Xcode command line tools)"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (install Xcode, then run xcode-select --switch)"
command -v ditto      >/dev/null 2>&1 || die "ditto not found"

ARCH_DIRS="ios-arm64 ios-sim-arm64 ios-sim-x86_64 macos-arm64 macos-x86_64"
for d in $ARCH_DIRS; do
  [ -f "$STAGE/$d/include/curl/curl.h" ] || die \
"missing or incomplete stage '$STAGE/$d'.

  Build all five Apple architectures first:
    build.sh --platform ios     --arch arm64
    build.sh --platform ios-sim --arch arm64
    build.sh --platform ios-sim --arch x86_64
    build.sh --platform macos   --arch arm64
    build.sh --platform macos   --arch x86_64"
done

WORK="$OUT/apple-work"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

# ── One merged archive per architecture ──────────────────────────────────────
# `libtool -static` is the only Apple-blessed way to concatenate static
# archives; `ar` loses the table of contents that ld64 needs for a fat member.
# -no_warning_for_no_symbols silences the (expected) header-only members.
for d in $ARCH_DIRS; do
  libs=""
  for lib in "$STAGE/$d/lib"/*.a; do
    [ -f "$lib" ] || continue
    libs="$libs $lib"
  done
  [ -n "$libs" ] || die "no .a files under $STAGE/$d/lib"
  # shellcheck disable=SC2086 # deliberate word splitting of the archive list
  libtool -static -no_warning_for_no_symbols -o "$WORK/$d.a" $libs
  echo "==> merged $d: $(lipo -archs "$WORK/$d.a")"
done

# ── Fat slices ───────────────────────────────────────────────────────────────
mkdir -p "$WORK/slices"
cp "$WORK/ios-arm64.a" "$WORK/slices/ios-device.a"
lipo -create "$WORK/ios-sim-arm64.a" "$WORK/ios-sim-x86_64.a" -output "$WORK/slices/ios-simulator.a"
lipo -create "$WORK/macos-arm64.a"   "$WORK/macos-x86_64.a"   -output "$WORK/slices/macos.a"

for s in ios-device ios-simulator macos; do
  echo "==> slice $s: $(lipo -archs "$WORK/slices/$s.a")"
done

# Headers are architecture independent — curl, BoringSSL and the ng* libraries
# all install identical public headers for every Apple architecture, so one copy
# serves the whole xcframework.
HEADERS="$WORK/Headers"
rm -rf "$HEADERS"
cp -R "$STAGE/ios-arm64/include" "$HEADERS"

# ── The xcframework ──────────────────────────────────────────────────────────
XCF="$WORK/NitroCurl.xcframework"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$WORK/slices/ios-device.a"    -headers "$HEADERS" \
  -library "$WORK/slices/ios-simulator.a" -headers "$HEADERS" \
  -library "$WORK/slices/macos.a"         -headers "$HEADERS" \
  -output "$XCF" >/dev/null

[ -f "$XCF/Info.plist" ] || die "xcodebuild produced no Info.plist in $XCF"

ZIP="$OUT/NitroCurl.xcframework.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$XCF" "$ZIP"
[ -s "$ZIP" ] || die "produced an empty $ZIP"

# Also place the framework inside the stage tree. The podspecs accept
# NITRO_HTTP_DEPS_DIR/NitroCurl.xcframework, and `export
# NITRO_HTTP_DEPS_DIR=<...>/out/stage` is the one line every doc prints — that
# single export must serve iOS/macOS exactly like it serves every CMake
# platform, or the first `flutter build ios` after a from-source build dies on
# 'curl/curl.h' file not found.
rm -rf "$STAGE/NitroCurl.xcframework"
cp -R "$XCF" "$STAGE/NitroCurl.xcframework"

# And vendor it into the plugin's own platform directories. With Swift Package
# Manager enabled (the Flutter default now), nitro_http builds through
# Package.swift and the podspec — with all its fetch logic — NEVER RUNS; the
# manifest can only resolve <platform>/Frameworks/NitroCurl.xcframework by
# path. Copying here is what makes a from-source build work for SPM and
# CocoaPods alike, in-repo and in the pub cache.
ROOT="$(cd "$HERE/../.." && pwd)"
for platform in ios macos; do
  mkdir -p "$ROOT/$platform/Frameworks"
  rm -rf "$ROOT/$platform/Frameworks/NitroCurl.xcframework"
  cp -R "$XCF" "$ROOT/$platform/Frameworks/NitroCurl.xcframework"
  # Record that this build put it here. The podspecs replace a framework they
  # installed themselves when the pin moves, but must never delete one somebody
  # built on purpose — an unstamped directory is indistinguishable from a stale
  # one, and a local build is exactly what you cannot re-download.
  printf 'local-build=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$ROOT/$platform/Frameworks/.nitro_curl_provenance"
  echo "==> vendored into $platform/Frameworks/NitroCurl.xcframework"
done

# ── The `apple-xcframework` CMake slice ──────────────────────────────────────
# Fat macOS archives, one file per component, because src/deps.cmake resolves
# curl, ssl, crypto, nghttp2 … individually and needs both host architectures to
# link. iOS is not represented here: nothing drives an iOS build through CMake.
SLICE_DIR="$STAGE/apple-xcframework"
rm -rf "$SLICE_DIR"
mkdir -p "$SLICE_DIR/lib"
cp -R "$STAGE/macos-arm64/include" "$SLICE_DIR/include"

for lib in "$STAGE/macos-arm64/lib"/*.a; do
  [ -f "$lib" ] || continue
  name="$(basename "$lib")"
  other="$STAGE/macos-x86_64/lib/$name"
  if [ -f "$other" ]; then
    lipo -create "$lib" "$other" -output "$SLICE_DIR/lib/$name"
  else
    die "$name exists for macos-arm64 but not macos-x86_64 — the two builds disagree"
  fi
done

# Reuse the arm64 manifest; only the target identity differs between the two
# macOS builds, and the merged slice is neither of them.
sed -e 's/"target": "[^"]*"/"target": "apple-xcframework",\
  "appleSlices": ["ios-arm64", "ios-sim-arm64", "ios-sim-x86_64", "macos-arm64", "macos-x86_64"]/' \
    "$STAGE/macos-arm64/manifest.json" > "$SLICE_DIR/manifest.json"
grep -q 'apple-xcframework' "$SLICE_DIR/manifest.json" || die "failed to rewrite manifest.json target"

TARBALL="$OUT/nitro-curl-apple-xcframework.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$SLICE_DIR" lib include manifest.json

for f in "$ZIP" "$TARBALL"; do
  size="$(wc -c < "$f" | tr -d ' ')"
  [ "$size" -gt 100000 ] || die "produced $f but it is only $size bytes — refusing to publish"
  echo "==> $f ($size bytes)"
done

echo "==> xcframework staged for CMake at $SLICE_DIR"
echo "    (usable directly: NITRO_HTTP_DEPS_DIR=$STAGE)"
echo "==> record the .zip checksum in the podspecs and Package.swift:"
shasum -a 256 "$ZIP"
