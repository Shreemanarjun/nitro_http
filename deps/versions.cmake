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
set(NITRO_HTTP_DEPS_BASE_URL
    "https://github.com/Shreemanarjun/nitro_http/releases/download/${NITRO_HTTP_DEPS_RELEASE}"
    CACHE STRING "Base URL for prebuilt dependency archives")

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
set(NH_SLICE_android-arm64-v8a_SHA256   "73280195b2d4b38861e528406ab89b53ba55381f62d2367c90a9888a532ebc83")
set(NH_SLICE_android-armeabi-v7a_SHA256 "3bec4b407fb6951d945ff92f5654bf1482b552f1e2ff2899d869d5df145ab93d")
set(NH_SLICE_android-x86_64_SHA256      "9b1f648f79af47a8f0fba92ebead8be0e16926abb1275c091e1c57a790c8a42f")
set(NH_SLICE_linux-x64_SHA256           "5a51cefe40e04a2b4d98e97934937d54e07462753929e83251ea4dee6f2374de")
set(NH_SLICE_linux-arm64_SHA256         "7a549ac8c5bf2076481c206ae2c02692dde07483fe544268977b9b3f70109359")
set(NH_SLICE_windows-x64_SHA256         "44112e4e814d333b5de83de3a829ff80ac537a1dd5476671e3dd05fc81c5d2d2")
set(NH_SLICE_apple-xcframework_SHA256   "abf9580cc3ca1d42ec84f3297661a5641b4565e0703284beab8d1f3ab539f456")

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
set(NH_APPLE_XCFRAMEWORK_ZIP_SHA256     "03627673224eaf0f7c01261826ae1291f5b62b6a5b2afa24f19046cc77c2fa2c")
