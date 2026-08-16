#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint nitro_http.podspec` to validate before publishing.
#

# Fetches Frameworks/NitroCurl.xcframework (libcurl + nghttp2/ngtcp2/nghttp3 +
# BoringSSL + brotli + zstd, merged into one xcframework by CI).
#
# Contract: it NEVER fails the install for a missing artifact. Someone who only
# wants the Dart layer, or who is offline, must still get a working
# `pod install`; they get a warning naming the three ways to obtain the binary.
# A *checksum mismatch* is the one hard failure — that is tampering, not
# absence.
nitro_curl_fetch = <<~'SH'
  set -eu

  frameworks_dir="nitro_http/Frameworks"
  framework="$frameworks_dir/NitroCurl.xcframework"
  archive_name="NitroCurl.xcframework.zip"

  versions="../deps/versions.cmake"
  release=$(sed -n 's/^set(NITRO_HTTP_DEPS_RELEASE "\([^"]*\)".*/\1/p' "$versions" 2>/dev/null | head -1) || true
  # NH_APPLE_XCFRAMEWORK_ZIP_SHA256, not NH_SLICE_apple-xcframework_SHA256: the
  # latter pins the .tar.gz src/deps.cmake downloads, which is a different
  # packing of the same objects and therefore a different checksum. Verifying
  # the .zip against it always mismatches, and a mismatch fails the install.
  expected=$(sed -n 's/^set(NH_APPLE_XCFRAMEWORK_ZIP_SHA256[[:space:]]*"\([^"]*\)").*/\1/p' "$versions" 2>/dev/null | head -1) || true
  [ -n "${release:-}" ] || release="deps-v1"
  url="https://github.com/Shreemanarjun/nitro_http/releases/download/$release/$archive_name"

  stamp="$frameworks_dir/.nitro_curl_provenance"

  # A vendored framework is only trustworthy if we know where it came from.
  #
  # This used to be `if [ -d "$framework" ]; then exit 0; fi` — the directory
  # existing was taken as proof it was the right one. It is not. A stale
  # xcframework left over from an earlier build sat here for a day: its iOS
  # slices had been built with HTTP/3 disabled while its macOS slice had it, so
  # `NitroHttp.supportsHttp3` reported false on device against a release that
  # ships h3 on every slice. Nothing re-checked it, because the directory was
  # there.
  #
  # So each install records what it put here, and a later install compares. The
  # rule for what to do on a mismatch is the important half:
  #
  #   * We wrote it and the pin has since moved   -> replace it. Safe, because
  #     the stamp proves this script owns the file.
  #   * Someone else put it there (a local build via tool/deps/merge_apple.sh,
  #     a hand-unzipped archive, NITRO_HTTP_DEPS_DIR) -> NEVER delete it. That
  #     is deliberate work, often on a machine that cannot re-download. Say the
  #     provenance does not match the pin and carry on.
  #
  # Caveat worth knowing: with Swift Package Manager this whole script never
  # runs, so an SPM-only build gets no check at all. Package.swift resolves
  # <platform>/Frameworks/NitroCurl.xcframework purely by path.
  want="release=${release:-none} sha=${expected:-none}"
  if [ -d "$framework" ]; then
    have=$(cat "$stamp" 2>/dev/null || true)
    if [ "$have" = "$want" ]; then
      exit 0
    elif [ -z "$have" ]; then
      echo "warning: nitro_http: $framework has no provenance stamp, so it cannot be" >&2
      echo "warning: nitro_http: checked against $want." >&2
      echo "warning: nitro_http: Keeping it — delete the directory to fetch the pinned build." >&2
      exit 0
    else
      case "$have" in
        release=*)
          echo "nitro_http: vendored framework is $have but the pin is now $want — refreshing"
          rm -rf "$framework" "$stamp"
          ;;
        *)
          echo "warning: nitro_http: $framework was supplied locally ($have), not by the" >&2
          echo "warning: nitro_http: pinned release ($want). Keeping it; delete it to switch." >&2
          exit 0
          ;;
      esac
    fi
  fi

  giveup() {
    echo "warning: nitro_http: $1" >&2
    echo "warning: nitro_http: NitroCurl.xcframework is missing, so the native HTTP engine will not link." >&2
    echo "warning: nitro_http: Do one of the following, then re-run \`pod install\`:" >&2
    echo "warning: nitro_http:   1. Build with network access so this step can fetch $url" >&2
    echo "warning: nitro_http:   2. Build the binary yourself (tool/deps/build.sh --platform ios --arch arm64," >&2
    echo "warning: nitro_http:      then tool/deps/merge_apple.sh) and export NITRO_HTTP_DEPS_DIR=<dir holding NitroCurl.xcframework>" >&2
    echo "warning: nitro_http:   3. Download $archive_name by hand and unzip it into ios/nitro_http/Frameworks/" >&2
    echo "warning: nitro_http: Installation continues; only the Dart layer of nitro_http is usable until then." >&2
    exit 0
  }

  tmp=""
  cleanup() { if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; return 0; }
  trap cleanup EXIT

  if [ -n "${NITRO_HTTP_DEPS_DIR:-}" ]; then
    # Air-gapped / corporate-proxy / local-superbuild path. Same environment
    # variable src/deps.cmake honours, so one export serves every platform.
    if [ -d "$NITRO_HTTP_DEPS_DIR/NitroCurl.xcframework" ]; then
      mkdir -p "$frameworks_dir"
      cp -R "$NITRO_HTTP_DEPS_DIR/NitroCurl.xcframework" "$frameworks_dir/"
      printf 'deps-dir=%s\n' "$NITRO_HTTP_DEPS_DIR" > "$stamp"
      echo "nitro_http: vendored NitroCurl.xcframework from NITRO_HTTP_DEPS_DIR"
      exit 0
    elif [ -f "$NITRO_HTTP_DEPS_DIR/$archive_name" ]; then
      archive="$NITRO_HTTP_DEPS_DIR/$archive_name"
      # Stamped by where it CAME FROM, not by the pin it happens to satisfy.
      # Labelling this `release=` would license a later pin bump to delete it,
      # and the whole point of NITRO_HTTP_DEPS_DIR is that re-downloading is
      # not an option here. It is still checksum-verified below when a pin
      # exists; the stamp records custody, the checksum records contents.
      origin=$(printf 'deps-dir=%s' "$NITRO_HTTP_DEPS_DIR")
    else
      giveup "NITRO_HTTP_DEPS_DIR='$NITRO_HTTP_DEPS_DIR' holds neither NitroCurl.xcframework nor $archive_name."
    fi
  else
    # An empty pin means no deps release has been cut yet; refusing to download
    # is better than trusting an unverified archive.
    [ -n "${expected:-}" ] || giveup "no SHA-256 is pinned for the Apple slice in deps/versions.cmake yet."

    # Cached in a USER-level directory keyed by the release tag, matching
    # src/deps.cmake. This archive is ~18 MB and used to land in `mktemp -d`,
    # so it was re-downloaded on every `pod install` in a new project and on
    # every nitro_http upgrade — even though deps-v1 has not moved across any
    # release so far. The pin makes the cache safe: a hit is only a hit when
    # the bytes already match the SHA-256 we are about to verify anyway.
    cache="${NITRO_HTTP_DEPS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nitro_http/deps}/$release"
    cached="$cache/$archive_name"
    if [ -f "$cached" ] && \
       [ "$(shasum -a 256 "$cached" 2>/dev/null | awk '{print $1}')" = "$expected" ]; then
      echo "nitro_http: using cached $archive_name ($cache)"
      archive="$cached"
    else
      mkdir -p "$cache" 2>/dev/null || cache=$(mktemp -d)   # unwritable HOME: still build
      cached="$cache/$archive_name"
      echo "nitro_http: downloading $url"
      # Download to .part and rename, so a concurrent `pod install` never sees
      # a half-written archive and treats it as a cache hit.
      curl -fsSL --retry 3 --connect-timeout 15 -o "$cached.part" "$url" \
        || giveup "download failed (no network, or the $release release has no Apple artifact)."
      mv -f "$cached.part" "$cached"
      archive="$cached"
    fi
  fi

  if [ -n "${expected:-}" ]; then
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
      echo "error: nitro_http: $archive_name SHA-256 mismatch." >&2
      echo "error: nitro_http:   expected $expected" >&2
      echo "error: nitro_http:   actual   $actual" >&2
      exit 1
    fi
  fi

  unzip -q -o "$archive" -d "$frameworks_dir"
  [ -d "$framework" ] || giveup "$archive_name did not contain NitroCurl.xcframework."
  printf '%s\n' "${origin:-$want}" > "$stamp"
  echo "nitro_http: vendored $framework (${origin:-$want})"
SH

# CocoaPods runs `prepare_command` only for pods it downloads. Flutter always
# installs plugin pods by `:path`, so the command below would never fire — run
# the identical script here, at podspec-evaluation time, which is early enough
# for `vendored_frameworks` to see the result.
system('/bin/sh', '-c', nitro_curl_fetch, chdir: __dir__)

Pod::Spec.new do |s|
  s.name             = 'nitro_http'
  s.version          = '0.0.1'
  s.summary          = 'A libcurl-backed HTTP client for Flutter, wired through Nitro FFI.'
  s.description      = <<-DESC
The iOS half of nitro_http: a C++ HTTP engine built on libcurl and driven over
Nitro for Flutter's zero-overhead FFI bridge. Supports HTTP/1.1, HTTP/2 and
HTTP/3, request and response streaming with credit-based backpressure,
cancellation, progress reporting, TLS/mTLS with SPKI pinning, proxies, DNS
overrides and DoH, cookies, a disk cache, and WebSockets.
                       DESC
  s.homepage         = 'https://github.com/Shreemanarjun/nitro_http'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Shreeman Arjun Sahu' => 'shreemanarjunsahu@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  # That forwarder pulls in src/engine/EngineUnity.cpp, which is why no engine
  # source is listed here.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.preserve_paths = 'nitro_http/Frameworks/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.dependency 'nitro'

  s.prepare_command = nitro_curl_fetch

  # Guarded: an absent xcframework must degrade gracefully, not into a CocoaPods
  # error about a missing vendored path.
  have_vendored_curl =
    File.directory?(File.join(__dir__, 'Frameworks', 'NitroCurl.xcframework'))
  if have_vendored_curl
    s.vendored_frameworks = 'nitro_http/Frameworks/NitroCurl.xcframework'
  end

  # z + resolv: libcurl's zlib transfer decoding and its threaded resolver.
  # Security + CoreFoundation: SecTrust chain evaluation in engine/CertStore.
  #
  # No `curl` fallback here, unlike macos/nitro_http.podspec: the iPhoneOS SDK
  # ships neither curl headers nor a libcurl stub, so a vendored slice is
  # mandatory on iOS. `pod install` still succeeds without one — the fetch
  # script above warns and exits 0 so a Dart-only consumer is not blocked — but
  # the Xcode build will then fail on undefined `curl_*` symbols. That is why the
  # warning names the three ways to supply a slice.
  s.libraries = 'z', 'resolv'
  s.frameworks       = 'Security', 'CoreFoundation', 'SystemConfiguration'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # engine/ContentDecoder inflates `br` and `zstd` itself — libcurl's own
    # content decoding is off — so these must track what is actually linked,
    # not what curl advertises. Only the vendored xcframework carries
    # libbrotlidec and libzstd; the SDK's system libcurl carries neither.
    # zlib needs no macro: ContentDecoder defaults NITRO_HTTP_HAS_ZLIB to 1.
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited)' +
      (have_vendored_curl ? ' NITRO_HTTP_HAS_BROTLI=1 NITRO_HTTP_HAS_ZSTD=1' : ''),
    # The trailing `/**` on the xcframework makes Xcode search every slice
    # recursively, so `#include <curl/curl.h>` resolves without hardcoding a
    # slice directory name (ios-arm64, ios-arm64_x86_64-simulator, …).
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/../.symlinks/plugins/nitro/src/native" "${PODS_TARGET_SRCROOT}/../src" "${PODS_TARGET_SRCROOT}/../src/engine" "${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp" "${PODS_TARGET_SRCROOT}/nitro_http/Frameworks/NitroCurl.xcframework/**"'
  }
  s.swift_version = '5.9'
end
