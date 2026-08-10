#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — build BoringSSL with every exported symbol renamed to <PREFIX>_*.
#
# Why this exists at all: on Apple platforms Nitro resolves native symbols with
# DynamicLibrary.process() and the plugin is *statically linked into the app
# binary*. If the host app also links OpenSSL — through any other plugin, or a
# vendored SDK — the duplicate SSL_*/EVP_* definitions are silently coalesced
# by the linker. The two libraries disagree about struct layout, so the first
# handshake reads garbage. Prefixing is the only fix that does not depend on
# what else the app happens to link.
#
# Usage:
#   prefix_symbols.sh --src DIR --build DIR --prefix DIR
#                     [--symbol-prefix NH] [--jobs N]
#                     [--obj-format elf|macho|pe] [-- <extra cmake args>]
#
# --obj-format overrides the object-file format handed to BoringSSL's symbol
# audit. It is normally derived from the target (the -DCMAKE_SYSTEM_NAME in the
# trailing cmake args), because BoringSSL's own default comes from the HOST and
# is therefore wrong for every cross build — an Android or Linux slice built on
# macOS is full of ELF objects and the Mach-O reader rejects the first one.
# Pass it explicitly when invoking this script by hand with no cmake args.
#
# Invoked by tool/deps/CMakeLists.txt, and usable by hand against any
# BoringSSL checkout when investigating a symbol collision.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

die() { printf '\nprefix_symbols.sh: %s\n\n' "$1" >&2; exit 1; }

SRC=""
BUILD=""
PREFIX=""
SYMBOL_PREFIX="NH"
JOBS=""
OBJ_FORMAT=""
CMAKE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --src)           SRC="${2:-}";           shift 2 ;;
    --build)         BUILD="${2:-}";         shift 2 ;;
    --prefix)        PREFIX="${2:-}";        shift 2 ;;
    --symbol-prefix) SYMBOL_PREFIX="${2:-}"; shift 2 ;;
    --jobs)          JOBS="${2:-}";          shift 2 ;;
    --obj-format)    OBJ_FORMAT="${2:-}";    shift 2 ;;
    --)              shift; CMAKE_ARGS=("$@"); break ;;
    -h|--help)       sed -n '2,27p' "$0"; exit 0 ;;
    *)               die "unknown argument '$1' (try --help)" ;;
  esac
done

[ -n "$SRC" ]    || die "--src is required"
[ -n "$BUILD" ]  || die "--build is required"
[ -n "$PREFIX" ] || die "--prefix is required"
[ -d "$SRC" ]    || die "--src '$SRC' is not a directory"
[ -f "$SRC/CMakeLists.txt" ] || die "--src '$SRC' does not look like a BoringSSL checkout (no CMakeLists.txt)"

case "$SYMBOL_PREFIX" in
  [A-Za-z_]*) ;;
  *) die "--symbol-prefix '$SYMBOL_PREFIX' must be a valid C identifier prefix" ;;
esac

# ── Which object-file format will the archives contain? ──────────────────────
# BoringSSL's audit_symbols.go defaults `-obj-file-format` from runtime.GOOS,
# i.e. from the HOST. That is wrong for every cross build: an Android slice
# assembled on macOS is full of ELF objects, and the Mach-O reader rejects the
# first one with `invalid magic number in record at byte 0x0`. Derive it from
# the TARGET instead, which tool/deps/CMakeLists.txt already forwards to us as
# -DCMAKE_SYSTEM_NAME. An explicit --obj-format wins, for hand invocations that
# pass no cmake args at all.
if [ -z "$OBJ_FORMAT" ]; then
  for arg in ${CMAKE_ARGS+"${CMAKE_ARGS[@]}"}; do
    case "$arg" in
      -DCMAKE_SYSTEM_NAME=*)
        case "${arg#-DCMAKE_SYSTEM_NAME=}" in
          Android|Linux)                  OBJ_FORMAT="elf" ;;
          Darwin|iOS|tvOS|watchOS|visionOS) OBJ_FORMAT="macho" ;;
          Windows|WindowsStore)           OBJ_FORMAT="pe" ;;
          # Anything else: say nothing and let BoringSSL's host default stand,
          # rather than guessing a format the reader will choke on.
        esac
        break
        ;;
    esac
  done
fi

case "$OBJ_FORMAT" in
  ""|elf|macho|pe) ;;
  *) die "--obj-format '$OBJ_FORMAT' must be one of elf, macho, pe" ;;
esac

command -v cmake >/dev/null 2>&1 || die "cmake not found on PATH"

# BoringSSL runs its own symbol audit (util/audit_symbols.go) as part of ALL
# whenever BORINGSSL_PREFIX is set, and the older two-pass flow needs Go to
# extract the symbol list. Either way the build cannot proceed without it.
command -v go >/dev/null 2>&1 || die \
"Go is required to build BoringSSL with prefixed symbols but was not found on PATH.

  BoringSSL verifies the prefixing with 'go run util/audit_symbols.go', which is
  part of its default build target when BORINGSSL_PREFIX is set.

  Install it:
    macOS         brew install go
    Debian/Ubuntu sudo apt-get install -y golang-go
    Windows       winget install GoLang.Go
    CI            actions/setup-go@v5

  Or skip building dependencies entirely and consume a published slice — see
  deps/versions.cmake and src/deps.cmake."

if [ -z "$JOBS" ]; then
  if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then JOBS="$(sysctl -n hw.ncpu)"
  else JOBS=2
  fi
fi

mkdir -p "$BUILD"

# ── Which prefixing flow does this checkout use? ─────────────────────────────
# BoringSSL replaced the two-pass flow in 2025: the per-symbol rename headers
# are now checked in as include/openssl/prefix_symbols.h and generated by
# util/pregenerate, so -DBORINGSSL_PREFIX alone is enough. Older checkouts
# still need the read_symbols.go round trip. Detect rather than assume, so the
# script stays correct if deps/versions.cmake ever pins backwards.
if [ -f "$SRC/util/read_symbols.go" ]; then
  FLOW="two-pass"
else
  [ -f "$SRC/include/openssl/prefix_symbols.h" ] || die \
"BoringSSL checkout at '$SRC' has neither util/read_symbols.go (old two-pass
  prefixing) nor include/openssl/prefix_symbols.h (pregenerated prefixing).
  NH_BORINGSSL_COMMIT in deps/versions.cmake may point at an unsupported
  revision."
  FLOW="pregenerated"
fi

echo "prefix_symbols.sh: BoringSSL prefixing flow = ${FLOW}, prefix = ${SYMBOL_PREFIX}_, objects = ${OBJ_FORMAT:-<host default>}"

# Locate the built archives regardless of BoringSSL's layout: older trees emit
# crypto/libcrypto.a and ssl/libssl.a, current ones put both at the build root,
# and MSVC produces .lib.
# (macOS still ships bash 3.2, so no `mapfile` and no `local -a` niceties.)
ARCHIVES=()
collect_archives() {
  local dir="$1" p
  ARCHIVES=()
  for p in \
      "$dir/libcrypto.a" "$dir/crypto/libcrypto.a" \
      "$dir/crypto.lib"  "$dir/crypto/crypto.lib" \
      "$dir/libssl.a"    "$dir/ssl/libssl.a" \
      "$dir/ssl.lib"     "$dir/ssl/ssl.lib"; do
    if [ -f "$p" ]; then ARCHIVES+=("$p"); fi
  done
  return 0
}

# Only the three installed targets. Building ALL would also compile libpki and
# libdecrepit (which nothing installs) and, more importantly, would run
# BoringSSL's `verify_boringssl_prefix` target — which shells out to
# `go run util/audit_symbols.go` with the *build* directory as its working
# directory. That only resolves when the build tree sits inside the source
# tree, which it never does here. The same audit is run below, from the
# right directory.
configure_and_build() {
  local bindir="$1"; shift
  cmake -S "$SRC" -B "$bindir" "${CMAKE_ARGS[@]+"${CMAKE_ARGS[@]}"}" "$@"
  cmake --build "$bindir" --parallel "$JOBS" --target crypto ssl bssl
}

if [ "$FLOW" = "two-pass" ]; then
  # Pass 1 exists only to produce object files to read symbol names out of.
  configure_and_build "$BUILD/pass1" -DBORINGSSL_PREFIX= -DBORINGSSL_PREFIX_SYMBOLS=

  collect_archives "$BUILD/pass1"
  [ "${#ARCHIVES[@]}" -gt 0 ] || die \
    "pass 1 produced no libcrypto/libssl archive under $BUILD/pass1"

  echo "prefix_symbols.sh: extracting symbols from ${ARCHIVES[*]}"
  ( cd "$SRC" && go run util/read_symbols.go -out "$BUILD/symbols.txt" "${ARCHIVES[@]}" )
  [ -s "$BUILD/symbols.txt" ] || die "read_symbols.go produced an empty symbols.txt"

  FINAL="$BUILD/pass2"
  configure_and_build "$FINAL" \
    "-DBORINGSSL_PREFIX=${SYMBOL_PREFIX}" \
    "-DBORINGSSL_PREFIX_SYMBOLS=$BUILD/symbols.txt"
else
  FINAL="$BUILD/prefixed"
  configure_and_build "$FINAL" "-DBORINGSSL_PREFIX=${SYMBOL_PREFIX}"
fi

cmake --install "$FINAL"

# The two-pass flow generates its rename headers into the build tree; downstream
# projects include <boringssl_prefix_symbols.h> from <openssl/base.h>, so they
# have to travel with the headers. (The pregenerated flow ships them inside
# include/openssl and install(DIRECTORY include/) already handled it.)
if [ "$FLOW" = "two-pass" ] && [ -d "$FINAL/symbol_prefix_include" ]; then
  mkdir -p "$PREFIX/include"
  cp "$FINAL"/symbol_prefix_include/*.h  "$PREFIX/include/" 2>/dev/null || true
  cp "$FINAL"/symbol_prefix_include/*.inc "$PREFIX/include/" 2>/dev/null || true
fi

# ── Verify the install is usable ─────────────────────────────────────────────
[ -f "$PREFIX/include/openssl/ssl.h" ] || die \
  "install completed but $PREFIX/include/openssl/ssl.h is missing"

INSTALLED_CRYPTO=""
for candidate in "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/crypto.lib"; do
  [ -f "$candidate" ] && INSTALLED_CRYPTO="$candidate"
done
[ -n "$INSTALLED_CRYPTO" ] || die \
  "install completed but no libcrypto archive landed in $PREFIX/lib"

# BoringSSL ships the authoritative check: audit_symbols.go walks every symbol
# in the archive and fails on anything defined outside the prefix. Run it on the
# artefacts that actually ship, from $SRC so Go can see boringssl's go.mod.
#
# Two classes of symbol survive prefixing and are tolerated:
#
#   _Z…   Itanium-ABI mangled C++ names (libssl carries a couple, e.g. the
#         ssl_session_st destructors). BORINGSSL_PREFIX only renames the C API.
#         These cannot collide with OpenSSL, which has no C++ at all — and
#         BoringSSL's own CMake audit only ever inspects libcrypto for exactly
#         this reason.
#   ?…    The same C++ names under the MSVC ABI (e.g. ??1ssl_session_st@@…,
#         the destructor pair MSVC emits as weak COMDATs). A C symbol can never
#         begin with '?', so this tolerates exactly the C++ mangling and
#         nothing else.
#   __clang_call_terminate   a weak compiler-runtime helper that every C++
#         translation unit may emit; the linker is required to coalesce it.
#
# Anything else — a stray SSL_new, a missed EVP_* — is a genuine defect and
# fails the build.
audit_archive() {
  local archive="$1" out rc found offenders
  local fmt_args=()
  if [ -n "$OBJ_FORMAT" ]; then fmt_args=(-obj-file-format "$OBJ_FORMAT"); fi
  set +e
  out="$( cd "$SRC" && go run util/audit_symbols.go \
            ${fmt_args+"${fmt_args[@]}"} \
            -ignore-symbols-with "$SYMBOL_PREFIX" "$archive" 2>&1 )"
  rc=$?
  set -e

  if [ $rc -eq 0 ]; then
    echo "prefix_symbols.sh: audited $(basename "$archive") — every symbol carries the ${SYMBOL_PREFIX} prefix"
    return 0
  fi

  found="$(printf '%s\n' "$out" | sed -n 's/^Found [a-z]* symbol without "[^"]*": //p')"
  # A non-zero exit with no findings means the tool itself failed (a Go
  # toolchain problem, an unreadable archive) — never treat that as a pass.
  [ -n "$found" ] || { printf '%s\n' "$out" >&2; die "audit_symbols.go failed on $archive"; }

  offenders="$(printf '%s\n' "$found" | grep -vE '^(_+Z[A-Za-z0-9_.$]+|\?[A-Za-z0-9_.$?@]+|_*__clang_call_terminate)$' || true)"
  if [ -n "$offenders" ]; then
    printf '%s\n' "$out" >&2
    die "unprefixed C symbols in $archive: $(printf '%s' "$offenders" | tr '\n' ' ')"
  fi

  echo "prefix_symbols.sh: audited $(basename "$archive") — clean apart from tolerated C++ ABI symbols: $(printf '%s' "$found" | tr '\n' ' ')"
}

audited="no"
if [ -f "$SRC/util/audit_symbols.go" ]; then
  for a in "$INSTALLED_CRYPTO" "$PREFIX/lib/libssl.a" "$PREFIX/lib/ssl.lib"; do
    [ -f "$a" ] || continue
    audit_archive "$a"
  done
  audited="yes"
fi

# Fallback for checkouts predating audit_symbols.go: spot-check the handful of
# names an app linking its own OpenSSL would collide on first.
if [ "$audited" = "no" ]; then
  command -v nm >/dev/null 2>&1 || die \
    "neither util/audit_symbols.go nor nm is available — cannot verify symbol prefixing"
  leaked="$(nm -g "$INSTALLED_CRYPTO" 2>/dev/null \
            | awk '$2 ~ /^[A-TV-Z]$/ { print $3 }' \
            | sed 's/^_//' \
            | grep -E '^(SSL_new|SSL_CTX_new|EVP_DigestInit_ex|CRYPTO_malloc|RSA_new)$' \
            || true)"
  [ -z "$leaked" ] || die \
    "prefixing did not take effect — $INSTALLED_CRYPTO still exports: $(echo "$leaked" | tr '\n' ' ')"
  echo "prefix_symbols.sh: spot-checked $(basename "$INSTALLED_CRYPTO") with nm"
fi

echo "prefix_symbols.sh: BoringSSL installed into $PREFIX with ${SYMBOL_PREFIX}_ prefix"
