#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — upgrade the vendored native dependency versions, then hand off to
# the deps-vN CI release that actually builds and publishes the prebuilt slices.
#
# The source pins in deps/versions.cmake are the only thing to edit; this
# automates the tedious, get-it-wrong-by-a-digit part: find each component's
# latest release, download the EXACT archive the superbuild will fetch, hash it,
# and rewrite NH_<COMP>_VERSION + NH_<COMP>_SHA256 in place. Hashing the real
# archive (not a published checksum) means the pin can never disagree with what
# CMake downloads.
#
# Two modes:
#
#   tool/deps/upgrade.sh                     bump every auto-safe component to latest
#   tool/deps/upgrade.sh --check             show what would change, write nothing
#   tool/deps/upgrade.sh --set curl=8.22.0   pin specific versions (repeatable)
#   tool/deps/upgrade.sh --pin deps-v2       after CI publishes: pin the built
#                                            slices and point the release at the tag
#
# BoringSSL and ngtcp2 are a PAIRED snapshot (ngtcp2's crypto/boringssl backend
# tracks a specific BoringSSL commit) — never auto-bumped. Bump ngtcp2 only with
# `--set ngtcp2=<ver>` and then re-pair BoringSSL per ngtcp2's README with
# `--set boringssl=<commit>`; this script will warn, not guess.
#
# The deps-vN tag push is deliberately NOT automated: cutting a release is
# one-way (the builds are not byte-reproducible, so a tag can never be re-pushed)
# and belongs to a human. This script prints the exact commands instead.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

VERSIONS="deps/versions.cmake"
# The components this script will bump to latest automatically.
AUTO="curl nghttp2 nghttp3 brotli zstd zlib"

die() { printf '\nupgrade.sh: %s\n\n' "$1" >&2; exit 1; }
warn() { printf 'upgrade.sh: %s\n' "$1" >&2; }

# ── Component knowledge ──────────────────────────────────────────────────────
# GitHub owner/repo a component's releases live under ("" = not on GitHub).
repo_of() {
  case "$1" in
    curl)      echo "curl/curl" ;;
    nghttp2)   echo "nghttp2/nghttp2" ;;
    nghttp3)   echo "ngtcp2/nghttp3" ;;
    ngtcp2)    echo "ngtcp2/ngtcp2" ;;
    brotli)    echo "google/brotli" ;;
    zstd)      echo "facebook/zstd" ;;
    zlib)      echo "madler/zlib" ;;
    *)         echo "" ;;
  esac
}

# The archive URL the superbuild downloads — kept identical to the ExternalProject
# URLs in tool/deps/CMakeLists.txt so the hash matches byte-for-byte.
url_of() {
  local v="$2"
  case "$1" in
    curl)    echo "https://curl.se/download/curl-$v.tar.xz" ;;
    nghttp2) echo "https://github.com/nghttp2/nghttp2/releases/download/v$v/nghttp2-$v.tar.xz" ;;
    nghttp3) echo "https://github.com/ngtcp2/nghttp3/releases/download/v$v/nghttp3-$v.tar.xz" ;;
    ngtcp2)  echo "https://github.com/ngtcp2/ngtcp2/releases/download/v$v/ngtcp2-$v.tar.xz" ;;
    brotli)  echo "https://github.com/google/brotli/archive/refs/tags/v$v.tar.gz" ;;
    zstd)    echo "https://github.com/facebook/zstd/releases/download/v$v/zstd-$v.tar.gz" ;;
    zlib)    echo "https://github.com/madler/zlib/releases/download/v$v/zlib-$v.tar.gz" ;;
    *)       echo "" ;;
  esac
}

# Uppercase a component name into its NH_<STEM>_* cmake variable stem. Avoids
# bash 4's ${x^^}, which macOS /bin/bash (3.2) does not have.
stem_of() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Latest stable release version, via the GitHub API. curl tags as `curl-8_22_0`;
# everyone else tags as `vX.Y.Z`.
latest_of() {
  command -v gh >/dev/null 2>&1 || return 0
  local repo tag
  repo="$(repo_of "$1")"
  [ -n "$repo" ] || return 0
  tag="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null)" || return 0
  case "$1" in
    curl) printf '%s' "$tag" | sed 's/^curl-//; s/_/./g' ;;
    *)    printf '%s' "$tag" | sed 's/^v//' ;;
  esac
}

cmake_value() { sed -n "s/^set($1[[:space:]]*\\([^ )]*\\).*/\\1/p" "$VERSIONS" | head -1; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# Download a URL and print its SHA-256, or nothing on failure.
hash_url() {
  local tmp; tmp="$(mktemp)"
  if curl -fsSL -o "$tmp" "$1" 2>/dev/null && [ -s "$tmp" ]; then sha256_of "$tmp"; fi
  rm -f "$tmp"
}

# Replace the value token of a `set(VAR  value)` line, preserving the leading
# alignment and any trailing `)  # comment`.
set_cmake() {
  perl -i -pe "s/^(set\\(\\Q$1\\E\\s+)\\S+(\\).*)\$/\${1}$2\${2}/" "$VERSIONS"
}

# ── Arguments ────────────────────────────────────────────────────────────────
CHECK=0
PIN_TAG=""
PIN_DIR=""
OVERRIDES=""   # "comp=ver;comp=ver;"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)  CHECK=1 ;;
    --set)    shift; OVERRIDES="$OVERRIDES${1:-};" ;;
    --pin)    shift; PIN_TAG="${1:-}" ;;
    --dir)    shift; PIN_DIR="${1:-}" ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done
[ -f "$VERSIONS" ] || die "run from the repo; $VERSIONS not found"

override_of() { printf '%s' "$OVERRIDES" | tr ';' '\n' | sed -n "s/^$1=//p" | head -1; }

# ── --pin: close the CI loop ─────────────────────────────────────────────────
if [ -n "$PIN_TAG" ]; then
  command -v gh >/dev/null 2>&1 || die "--pin needs the gh CLI"
  dir="${PIN_DIR:-$(mktemp -d)}"
  echo "==> downloading $PIN_TAG release assets into $dir"
  gh release download "$PIN_TAG" -D "$dir" --clobber \
    || die "could not download release $PIN_TAG (is it published yet?)"
  echo "==> pinning slice checksums"
  tool/deps/publish.sh --dir "$dir" || die "publish.sh failed"
  echo "==> pointing NITRO_HTTP_DEPS_RELEASE at $PIN_TAG"
  perl -i -pe "s/(set\\(NITRO_HTTP_DEPS_RELEASE\\s+\")[^\"]+(\")/\${1}$PIN_TAG\${2}/" "$VERSIONS"
  tool/deps/publish.sh --check || warn "pins do not verify — inspect $VERSIONS"
  echo
  echo "Done. Review and commit $VERSIONS, then rebuild the app."
  exit 0
fi

# ── Bump source versions ─────────────────────────────────────────────────────
# Any component named with --set is eligible, including the paired ones; the
# auto set is bumped to latest unless an override pins it.
want="$AUTO"
for kv in $(printf '%s' "$OVERRIDES" | tr ';' ' '); do
  comp="${kv%%=*}"
  case " $want " in *" $comp "*) ;; *) want="$want $comp" ;; esac
done

echo "==> nitro_http dependency upgrade${CHECK:+ (check only)}"
changed=0
touched_pair=0
for comp in $want; do
  stem="$(stem_of "$comp")"
  cur="$(cmake_value "NH_${stem}_VERSION")"

  # BoringSSL is a commit, not a release; bump the commit line only, no archive.
  if [ "$comp" = "boringssl" ]; then
    tgt="$(override_of boringssl)"
    [ -n "$tgt" ] || { warn "boringssl is a commit — pin it with --set boringssl=<commit>"; continue; }
    old="$(cmake_value NH_BORINGSSL_COMMIT)"
    [ "$tgt" = "$old" ] && { echo "  boringssl $old (unchanged)"; continue; }
    echo "  boringssl $old -> $tgt"
    [ "$CHECK" = 1 ] || set_cmake NH_BORINGSSL_COMMIT "$tgt"
    changed=1; touched_pair=1
    continue
  fi

  tgt="$(override_of "$comp")"
  [ -n "$tgt" ] || tgt="$(latest_of "$comp")"
  if [ -z "$tgt" ]; then
    warn "could not determine a version for $comp (no gh, or no release) — use --set $comp=<ver>"
    continue
  fi
  if [ "$tgt" = "$cur" ]; then
    echo "  $comp $cur (latest)"
    continue
  fi

  url="$(url_of "$comp" "$tgt")"
  sha="$(hash_url "$url")"
  if [ -z "$sha" ]; then
    warn "download failed for $comp $tgt — $url"
    continue
  fi
  echo "  $comp $cur -> $tgt"
  echo "      $url"
  echo "      sha256 $sha"
  [ "$comp" = "ngtcp2" ] && touched_pair=1
  if [ "$CHECK" != 1 ]; then
    set_cmake "NH_${stem}_VERSION" "$tgt"
    set_cmake "NH_${stem}_SHA256" "$sha"
  fi
  changed=1
done

echo
if [ "$changed" = 0 ]; then
  echo "Everything is already on the pinned version. Nothing to do."
  exit 0
fi
if [ "$CHECK" = 1 ]; then
  echo "Check only — $VERSIONS not modified. Re-run without --check to apply."
  exit 0
fi

if [ "$touched_pair" = 1 ]; then
  warn "ngtcp2/BoringSSL are a PAIR — if you bumped one, re-pair the other per"
  warn "ngtcp2's release notes (--set boringssl=<commit>) before cutting a release."
fi

cat <<EOF
Updated $VERSIONS (source pins only). The prebuilt slices still carry the old
versions until a new deps release is built. To ship:

  1. gh workflow run build-deps          # dry-run the full matrix first (optional)
  2. git tag deps-vN && git push origin deps-vN     # builds + publishes the slices
  3. tool/deps/upgrade.sh --pin deps-vN   # pins the built slices, points the release
  4. commit $VERSIONS

Never re-push an existing deps-vN tag — the builds are not reproducible. Cut N+1.
EOF
