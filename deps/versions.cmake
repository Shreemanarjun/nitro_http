# ─────────────────────────────────────────────────────────────────────────────
# nitro_http — single source of truth for native dependency versions.
#
# Consumed by:
#   • src/deps.cmake            (app-build-time resolution of prebuilt archives)
#   • tool/deps/CMakeLists.txt (the superbuild that produces those archives)
#   • .github/workflows/build-deps.yml
#
# ⚠️  ngtcp2 and BoringSSL are a PAIR. ngtcp2's `crypto/boringssl` backend
#     tracks specific BoringSSL snapshots and will not compile against a
#     mismatched revision. The commit below is the one named as tested in
#     ngtcp2 v1.25.0's README. Bumping either REQUIRES bumping both and
#     re-reading ngtcp2's release notes.
# ─────────────────────────────────────────────────────────────────────────────

set(NITRO_HTTP_DEPS_RELEASE "deps-v1"
    CACHE STRING "GitHub release tag holding the prebuilt dependency archives")
# NOT a CACHE variable, deliberately.
#
# `set(... CACHE STRING ...)` only initialises an entry that does not exist yet,
# so a build directory configured before this URL last changed keeps serving the
# OLD value forever — and CMake caches persist in places nobody thinks to clean,
# notably Gradle's `android/.cxx/<config>/<hash>/<abi>/CMakeCache.txt`. When the
# GitHub org in this URL was corrected, every existing Android build directory
# went on downloading from the old one and failed with
#
#     file DOWNLOAD HASH mismatch
#       expected hash: [6b91fbb0...]
#         actual hash: [e3b0c442...]     <- SHA-256 of an empty file, i.e. a 404
#
# which points at the checksum rather than at the four-month-old cache entry
# actually responsible. A plain variable is recomputed on every configure, so it
# cannot go stale.
#
# An explicit `-DNITRO_HTTP_DEPS_BASE_URL=...` still wins: that lands in the
# cache, `DEFINED` sees it, and the default below is skipped — so the override
# escape hatch is intact without a persistent copy of the default.
if(NOT DEFINED NITRO_HTTP_DEPS_BASE_URL)
  set(NITRO_HTTP_DEPS_BASE_URL
      "https://github.com/Shreemanarjun/nitro_http/releases/download/${NITRO_HTTP_DEPS_RELEASE}")
endif()

# ── Component versions ───────────────────────────────────────────────────────
set(NH_CURL_VERSION      8.21.0)
set(NH_NGHTTP2_VERSION   1.70.0)
set(NH_NGTCP2_VERSION    1.25.0)
set(NH_NGHTTP3_VERSION   1.18.0)
set(NH_BORINGSSL_COMMIT  22a0079b189c391b95689813a41982ce11876f0a)  # paired with ngtcp2
set(NH_BROTLI_VERSION    1.2.0)
set(NH_ZSTD_VERSION      1.5.7)
set(NH_ZLIB_VERSION      1.3.2)   # vendored on Windows/Linux only

# ── Source archive checksums (used by the superbuild) ────────────────────────
set(NH_CURL_SHA256     aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6)
set(NH_NGHTTP2_SHA256  e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2)
set(NH_NGTCP2_SHA256   2a34d2484ba17847a5d11965704e9dd0fac4c6d8efc75ffe1ec7de66d8c6b6fb)
set(NH_NGHTTP3_SHA256  aad782c23d3f01bd4bb52c8bac7a553b631ef8115fd1612703df6183449fef19)
set(NH_BROTLI_SHA256   816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec)
set(NH_ZSTD_SHA256     eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3)
set(NH_ZLIB_SHA256     bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16)

# ── Prebuilt slice checksums ─────────────────────────────────────────────────
# Populated by `tool/deps/publish.sh` when a deps-vN release is cut. An empty
# value means "no pin recorded yet"; src/deps.cmake then refuses to download
# rather than trusting an unverified archive.
#
# ⚠️  THE BUILDS ARE NOT BYTE-REPRODUCIBLE. Archive metadata and manifest.json
#     timestamps differ per run, so rebuilding a deps-vN tag produces archives
#     with different checksums and the release job REPLACES the published
#     assets. Every pin below then describes files that no longer exist, and
#     every consumer build fails with a HASH mismatch — which is exactly what
#     happened once already, when the tag was force-moved during a history
#     rewrite and quietly triggered a rebuild.
#
#     So: never re-push an existing deps-vN tag. Cut deps-v(N+1) instead. If a
#     tag does move, re-run `tool/deps/publish.sh --dir <downloaded assets>`
#     and commit the result before anyone builds.
set(NH_SLICE_android-arm64-v8a_SHA256   "6b91fbb0b857fad81b5738db96e968ab9c8448a09c2b4674ce2933b67d48e30b")
set(NH_SLICE_android-armeabi-v7a_SHA256 "32672acf02a2f28674ff9f312fadee9f24f49a03cce5d9d918097cf6efe5cde5")
set(NH_SLICE_android-x86_64_SHA256      "01dbb0912af563d2916e276977c3478832a9d019906351dc511dff715d1fabce")
set(NH_SLICE_linux-x64_SHA256           "7559cc7ac1270330e4b689152a72e951dad94e6206d258d2f0bbdb0d9753b3e6")
set(NH_SLICE_linux-arm64_SHA256         "293595ae0f3d56d5b469cd87e70231ef7f9fe20c84d44fcd440a7a061939f1f3")
set(NH_SLICE_windows-x64_SHA256         "30671eaf7d4c7a1287ac98d9c8e484a5a6875d6ee521a633934778e25a8045d2")
set(NH_SLICE_apple-xcframework_SHA256   "81c29b579f0bb9a6e3fa5a6c2c325e12e7c65ff72b70d63b755c5e6480498ba4")

# The Apple release carries TWO artifacts built from the same objects but packed
# differently, so they have different checksums and need different pins:
#
#   nitro-curl-apple-xcframework.tar.gz   → NH_SLICE_apple-xcframework_SHA256,
#                                           downloaded by src/deps.cmake
#   NitroCurl.xcframework.zip             → the pin below, downloaded by the
#                                           CocoaPods podspecs
#
# Verifying the .zip against the .tar.gz pin is a guaranteed mismatch, and the
# podspecs treat a mismatch as tampering and fail the install outright.
set(NH_APPLE_XCFRAMEWORK_ZIP_SHA256     "ec24145c92c6dc6ea2c89b262d6c93da593838e1ca458dc86e9f1b170a866ce0")
