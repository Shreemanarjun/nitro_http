#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — pin the produced archives in deps/versions.cmake.
#
# src/deps.cmake refuses to download a slice whose NH_SLICE_<name>_SHA256 is
# empty, on purpose: an unpinned download is an unverified download. This script
# closes that loop after a build — it hashes every `nitro-curl-<slice>.tar.gz`
# it finds and rewrites the matching value in place.
#
#   ./publish.sh                        # hash everything in tool/deps/out
#   ./publish.sh --dir dist             # hash everything in ./dist
#   ./publish.sh --check                # verify pins match, change nothing
#
# NitroCurl.xcframework.zip is pinned too, in NH_APPLE_XCFRAMEWORK_ZIP_SHA256
# rather than an NH_SLICE_ slot: CMake never downloads it, the CocoaPods
# podspecs do, and it is a different packing of the Apple objects than
# nitro-curl-apple-xcframework.tar.gz, so the two checksums differ.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSIONS="$(cd "$HERE/../.." && pwd)/deps/versions.cmake"

die() { printf '\npublish.sh: %s\n\n' "$1" >&2; exit 1; }

DIR="$HERE/out"
CHECK="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="${2:-}"; shift 2 ;;
    --check) CHECK="yes";  shift ;;
    -h|--help)
      sed -n '3,17p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -d "$DIR" ]      || die "'$DIR' is not a directory (build the slices first, or pass --dir)"
[ -f "$VERSIONS" ] || die "cannot find $VERSIONS"

# sha256sum on GNU userland, shasum on macOS. Both print "<hash>  <path>".
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "neither sha256sum nor shasum found on PATH"
fi

# GNU sed wants `-i`, BSD sed wants `-i ''`. Probing beats guessing from uname:
# a Mac with coreutils/gnu-sed on PATH would break the uname heuristic.
sed_inplace() {
  local expr="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i -e "$expr" "$file"
  else
    sed -i '' -e "$expr" "$file"
  fi
}

# Every slice src/deps.cmake can ask for. Kept explicit so a typo in an archive
# name is reported instead of silently skipped.
KNOWN_SLICES="android-arm64-v8a android-armeabi-v7a android-x86_64 linux-x64 linux-arm64 windows-x64 apple-xcframework"

is_known() {
  local needle="$1" s
  for s in $KNOWN_SLICES; do
    [ "$s" = "$needle" ] && return 0
  done
  return 1
}

found_any="no"
mismatch="no"

for archive in "$DIR"/nitro-curl-*.tar.gz; do
  [ -f "$archive" ] || continue
  base="$(basename "$archive")"
  slice="${base#nitro-curl-}"
  slice="${slice%.tar.gz}"

  is_known "$slice" || die \
"'$base' does not name a slice src/deps.cmake knows about.

  Expected one of: $KNOWN_SLICES
  A mismatched name here produces a release nothing can download."

  grep -q "NH_SLICE_${slice}_SHA256" "$VERSIONS" || die \
    "deps/versions.cmake has no NH_SLICE_${slice}_SHA256 entry for '$base'"

  hash="$(sha256 "$archive")"
  current="$(sed -n "s/^set(NH_SLICE_${slice}_SHA256[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$VERSIONS")"
  found_any="yes"

  if [ "$CHECK" = "yes" ]; then
    if [ "$current" = "$hash" ]; then
      echo "ok       $slice"
    else
      echo "MISMATCH $slice: pinned='$current' actual='$hash'" >&2
      mismatch="yes"
    fi
    continue
  fi

  if [ "$current" = "$hash" ]; then
    echo "unchanged $slice"
    continue
  fi

  # Rewrite only the quoted value, preserving the alignment in versions.cmake.
  sed_inplace \
    "s|^\\(set(NH_SLICE_${slice}_SHA256[[:space:]]*\\)\"[^\"]*\"|\\1\"${hash}\"|" \
    "$VERSIONS"

  new="$(sed -n "s/^set(NH_SLICE_${slice}_SHA256[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$VERSIONS")"
  [ "$new" = "$hash" ] || die \
    "failed to write NH_SLICE_${slice}_SHA256 (still '$new') — check the file is writable"
  echo "pinned   $slice = $hash"
done

if [ "$found_any" = "no" ]; then
  die "no nitro-curl-*.tar.gz archives found in '$DIR' — nothing to publish"
fi

# The .zip is a SECOND packing of the same Apple objects, so its checksum is not
# the .tar.gz's. It gets its own variable for exactly that reason: the podspecs
# used to verify the .zip against NH_SLICE_apple-xcframework_SHA256, which can
# only ever mismatch, and a mismatch there is a hard `pod install` failure.
XCF_ZIP="$DIR/NitroCurl.xcframework.zip"
if [ -f "$XCF_ZIP" ]; then
  hash="$(sha256 "$XCF_ZIP")"
  current="$(sed -n 's/^set(NH_APPLE_XCFRAMEWORK_ZIP_SHA256[[:space:]]*"\([^"]*\)").*/\1/p' "$VERSIONS")"

  if [ "$CHECK" = "yes" ]; then
    if [ "$current" = "$hash" ]; then
      echo "ok       apple-xcframework-zip"
    else
      echo "MISMATCH apple-xcframework-zip: pinned='$current' actual='$hash'" >&2
      mismatch="yes"
    fi
  elif [ "$current" = "$hash" ]; then
    echo "unchanged apple-xcframework-zip"
  else
    sed_inplace \
      "s|^\\(set(NH_APPLE_XCFRAMEWORK_ZIP_SHA256[[:space:]]*\\)\"[^\"]*\"|\\1\"${hash}\"|" \
      "$VERSIONS"
    new="$(sed -n 's/^set(NH_APPLE_XCFRAMEWORK_ZIP_SHA256[[:space:]]*"\([^"]*\)").*/\1/p' "$VERSIONS")"
    [ "$new" = "$hash" ] || die \
      "failed to write NH_APPLE_XCFRAMEWORK_ZIP_SHA256 (still '$new') — check the file is writable"
    echo "pinned   apple-xcframework-zip = $hash"
  fi
fi

if [ "$CHECK" = "yes" ]; then
  [ "$mismatch" = "no" ] || die "one or more pins do not match the built archives"
  echo
  echo "all pins match"
  exit 0
fi

echo
if command -v git >/dev/null 2>&1 && git -C "$(dirname "$VERSIONS")" rev-parse --git-dir >/dev/null 2>&1; then
  git --no-pager -C "$(dirname "$VERSIONS")" diff -- "$VERSIONS" || true
else
  echo "(not a git checkout — resulting pins:)"
  grep '^set(NH_SLICE_' "$VERSIONS"
fi
