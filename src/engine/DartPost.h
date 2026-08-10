// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — the native-async completion seam.
//
// Every accepted `sendBuffered` / `startStreamed` / `prefetch` / `wsConnect`
// posts EXACTLY ONE message to its Dart port. A request that never posts hangs
// a Dart `Future` forever, which is why cancellation posts `cancelled`, engine
// shutdown posts `engineError`, and a malformed request posts `badRequest`
// rather than any of them quietly dropping the port.
//
// `Dart_PostCObject_DL` returns false for a dead port — which is exactly what
// happens on hot restart, where the Dart isolate is torn down while native
// threads keep running. Every post site therefore frees the blob it would have
// transferred and lets the caller abort the associated work.
//
// Tests replace the post function wholesale, which is how the engine test
// suite runs without a Dart VM.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

#include "Common.h"

namespace nitrohttp {

/// Posts `blob` (a malloc'd `[4B len][payload]` record) to `port` as a
/// `Dart_CObject_kInt64` holding its address. Dart's generated `unpack`
/// decodes it and calls `nitro_http_nitro_free`.
///
/// Takes ownership unconditionally: on a dead port the blob is freed here and
/// `false` is returned. Never returns without the blob accounted for.
bool postRecord(int64_t port, Blob blob);

/// Posts `kNull`, which Dart's generated unpack turns into a
/// `HybridException` for a non-nullable result. Reserved for the genuinely
/// unrecoverable — a failure to even *encode* the error envelope. Ordinary
/// transport failures ride inside the record.
bool postNull(int64_t port);

/// Posts a whole batch of completions as ONE `kArray` of int64,
/// `[callId0, addr0, callId1, addr1, …]` — the wire `NitroCoalescer` decodes.
///
/// This is the entire point of coalescing: N completions that finish together
/// cost ONE isolate wake instead of N. Each `addr` is an encoded record's
/// malloc'd pointer widened to int64, and ownership passes to Dart exactly as it
/// does for `postRecord` — Dart decodes and calls `nitro_http_nitro_free`.
///
/// Takes ownership unconditionally, like `postRecord`: on a dead port every blob
/// in the batch is freed here and `false` is returned, so a hot restart cannot
/// leak the burst it was holding.
bool postCoalescedBatch(int64_t port,
                        const std::vector<std::pair<int64_t, int64_t>>& items);

/// Test seam. `hook` receives ownership of the blob exactly as
/// `Dart_PostCObject_DL` would and returns whether the port was alive.
/// Passing `nullptr` restores the real Dart post.
using PostHook = std::function<bool(int64_t port, Blob blob)>;
void setPostHook(PostHook hook);

/// Test seam for [postCoalescedBatch]. Same contract: the hook owns every blob
/// in the batch. `nullptr` restores the real Dart post.
using BatchHook =
    std::function<bool(int64_t port,
                       const std::vector<std::pair<int64_t, int64_t>>& items)>;
void setBatchHook(BatchHook hook);

/// True when the Dart API DL has been initialised, i.e. posting is possible.
/// False inside the C++ test binary, where the hook is used instead.
bool dartPostAvailable();

}  // namespace nitrohttp
