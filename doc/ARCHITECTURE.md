# nitro_http — architecture

For maintainers. This document explains *why* the code is shaped the way it is,
in the order you need to know it: the layers, the two request lifecycles, the
framework constraints that forced the design, the payload-ownership protocol
(the one invariant that is easy to break invisibly), the credit loop, the
threading contract, and a file-by-file map.

The user-facing story is in `README.md`.

## Contents

1. [Layers](#1-layers)
2. [Instance-key role routing](#2-instance-key-role-routing)
3. [Request lifecycles](#3-request-lifecycles)
4. [The four framework constraints](#4-the-four-framework-constraints)
5. [Payload ownership: the ack protocol](#5-payload-ownership-the-ack-protocol)
6. [The credit loop](#6-the-credit-loop)
7. [Threading contract](#7-threading-contract)
8. [Memory ownership, exhaustively](#8-memory-ownership-exhaustively)
9. [File map](#9-file-map)
10. [Invariant checklist](#10-invariant-checklist)

---

## 1. Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  Application code                                                   │
│    NitroHttpClient · fetch() · NitroWebSocket · package:http · dio  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────────┐
│  Public Dart API   lib/src/api/ — pure Dart, no FFI, no Raw* types  │
│    settings · sealed HttpBody · sealed HttpResponse · exceptions    │
│    interceptor chain · RetryPolicy · CancelToken · CookieJar        │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────────┐
│  Runner            lib/src/internal/                                │
│    raw_mapping   typed ↔ Raw* translation, error table              │
│    request_runner buffered/streamed routing · credit loop ·         │
│                   upload pump · single-subscriber demux             │
│    ws_runner · engine_runner · instance_keys                        │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  generated bindings (nitrogen)
┌───────────────────────────────▼─────────────────────────────────────┐
│  Nitro bridge      sync call ≈0.26 µs · native-async port post ·    │
│                    module-global streams                            │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  C ABI
┌───────────────────────────────▼─────────────────────────────────────┐
│  C++ engine        src/engine/, namespace nitrohttp                 │
│    EngineRegistry ──► CurlEngine (one per client)                   │
│                        ├── loop thread: curl_multi + curl_share     │
│                        ├── RequestTask · BodyPipe · ChunkArena      │
│                        ├── CertStore · CookieBridge                 │
│                        └── HttpCache (IO thread) · WsSession(s)     │
│                       DeferredPayloads (process-global)             │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────────┐
│  libcurl · nghttp2 · ngtcp2 + nghttp3 · BoringSSL (NH_ prefixed)    │
│  brotli · zstd · zlib          — static, SHA-256 pinned             │
└─────────────────────────────────────────────────────────────────────┘
```

Two rules keep the layering honest:

- **Only `raw_mapping.dart` and `request_runner.dart` import the generated spec.**
  Everything above them speaks `ClientSettings` / `HttpRequest` / `HttpResponse`;
  everything below speaks records with sentinel conventions. If a `Raw*` type
  appears in `lib/src/api/`, a layer has leaked.
- **The engine never depends on the generated bridge *class*.** `src/engine/`
  talks to Dart through two seams declared in `Common.h` — a stream sink and a
  post hook — which is what lets the C++ test suite link without a Dart runtime.

---

## 2. Instance-key role routing

One `*.native.dart` spec generates one shared library. Two spec files could not
share a `curl_multi` pool, a cookie jar or a disk cache without fragile
cross-dylib symbol wiring on five platforms. So there is exactly one spec class,
`NitroHttp`, and roles ride on the multi-instance factory key that the C++
factory parses:

| Key | Backing object | Allocated by |
|---|---|---|
| `engine` | Process-wide singleton: cache config, prefetch, capability queries | constant `kEngineKey` |
| `c:<clientId>` | One `CurlEngine`: loop thread, pool, cookie jar, TLS config | `Ids.nextClient()` |
| `ws:<socketId>` | One `WsSession` | `Ids.nextSocket()` |

`EngineRegistry::resolve(key)` returns a `RoleHandle`, which is what the hybrid
object holds. Calling a method that does not belong to the handle's role throws
`std::runtime_error`, which the generated bridge converts into a Dart
`HybridException` — the right channel, because a client-role call on a WebSocket
instance is a programming error, not a transport failure.

Request ids (`Ids.nextRequest()`) are **process-global, not per-client**. The
`chunks` and `events` streams are module-global (see §4.3), so two clients
handing out the same id would cross-deliver each other's chunks.

---

## 3. Request lifecycles

### 3.1 Buffered

The common case: a JSON call whose response fits in memory. One FFI call out,
one port post back, no streams involved.

```mermaid
sequenceDiagram
    autonumber
    participant App as App
    participant Run as RequestRunner
    participant Eng as CurlEngine (Dart thread)
    participant Loop as Loop thread
    participant Port as Dart port

    App->>Run: client.get(...)
    Note over Run: interceptors beforeRequest<br/>encodeBody, toRawRequest
    Run->>Eng: sendBuffered(raw, bodyBytes)
    Note over Eng: deep-copy record + body<br/>(the Nitro arena dies on return)
    Eng->>Loop: inbox.push(Submit) + curl_multi_wakeup
    Eng-->>Run: returns immediately
    Loop->>Loop: cache lookup; fresh hit short-circuits
    Loop->>Loop: curl_multi_add_handle
    Loop->>Loop: HEADERFUNCTION accumulates headers
    Loop->>Loop: WRITEFUNCTION appends to bodyBuf_
    Loop->>Loop: CURLMSG_DONE: collect CURLINFO_*, cache write-back
    Loop->>Port: post RawResponse blob (exactly once)
    Port-->>Run: unpack record, free blob
    Note over Run: errorKind != none -> mapError()<br/>else build metadata + response<br/>throwOnStatusCode check
    Run->>App: HttpTextResponse / HttpBytesResponse
    Note over App: interceptors afterResponse / onError
```

**Exactly-once completion** is the load-bearing invariant. Every accepted
`sendBuffered` posts precisely one message to its port: cancellation posts
`errorKind: cancelled`, shutdown posts `engineError`, a malformed request posts
`badRequest`. A task that never posts hangs a Dart `Future` forever, so
`RequestTask::complete()` is idempotent and asserts that it fired.

### 3.2 Streamed

Used for `HttpExpectedBody.stream` — large downloads, server-sent events,
progressive rendering.

```mermaid
sequenceDiagram
    autonumber
    participant App as App
    participant Run as RequestRunner
    participant Dmx as NativeStreamDemux
    participant Loop as Loop thread
    participant Arena as ChunkArena

    Note over Run,Dmx: subscribe BEFORE starting —<br/>a fast server can deliver a chunk<br/>in the same turn as the head
    Run->>Dmx: chunks(requestId)
    Run->>Loop: startStreamed(raw, bodyBytes)
    Loop->>Run: post RawResponseHead
    Note over Run: build metadata, resolve<br/>Future<HttpStreamResponse>
    App->>Run: listen(response.body)
    Run->>Loop: grantCredit(id, 16, acked=0)
    loop while credits remain
        Loop->>Arena: track(seq, payload)
        Loop-->>Dmx: emit RawChunk{data, seq}
        Dmx->>Dmx: COPY bytes out of native memory
        Dmx-->>Run: ChunkEvent
        Run->>App: controller.add(bytes)
    end
    Note over Loop: credits exhausted: WRITEFUNCTION returns<br/>CURL_WRITEFUNC_PAUSE and the TCP window closes
    Run->>Loop: grantCredit(id, 8, acked=N)
    Loop->>Arena: ack(N) — frees payloads with seq < N
    Loop->>Loop: curl_easy_pause(CURLPAUSE_CONT)
    Loop-->>Dmx: emit RawChunk{done}
    Run->>Loop: grantCredit(id, 0, acked=N+1)
    Note over Run: close controller, demux.release(id)
```

Upload streaming is the mirror image: `feedUploadChunk(id, bytes)` copies into
`BodyPipe`'s bounded ring and returns the currently buffered byte count;
`READFUNCTION` drains the ring and returns `CURL_READFUNC_PAUSE` when it is empty
and the stream has not ended. The runner pauses its Dart source above
`kUploadHighWaterMark` (1 MiB) and resumes on an `uploadDrain` event.

---

## 4. The four framework constraints

Each of these was verified against Nitro's source, and each one directly removed
a design option. Getting any of them wrong produces a client that demos fine and
falls over under concurrency.

### 4.1 `@nitroAsync` cannot carry a network request

`@nitroAsync` dispatches to an `IsolatePool` worker where the call runs
**synchronously**, and `NitroConfig.isolatePoolSize` defaults to **1**. A
blocking HTTP call on that single worker would serialize every other
`@nitroAsync` call in the entire application, including calls from unrelated
Nitro plugins.

**Therefore:** every request-initiating method is `@nitroNativeAsync`. Native
receives an extra `int64 dart_port`, returns immediately, performs the transfer
on its own thread, and posts exactly one result with `Dart_PostCObject_DL`. No
Dart isolate is occupied for the duration of a request, and concurrent in-flight
calls on one instance are explicitly supported.

### 4.2 Errors must ride inside the result record

`@NitroResult` (the sealed `NitroOk`/`NitroErr` pair) cannot be combined with
`@nitroNativeAsync`: the validator rejects it with **E015**, because
`Dart_PostCObject_DL` can only encode primitive CObject types, not a result
buffer. The plain native-async failure path is impoverished — native posts
`kNull` and Dart sees `null`, with no message.

**Therefore:** transport failures are **not exceptions at the bridge**. Every
response record starts with an error envelope: `errorKind`, `errorMessage`,
`engineErrorCode` (the raw `CURLcode`). `errorKind == none` means the transfer
completed; the HTTP status is a separate field, so a 500 is a *success* at this
layer. Turning a 4xx/5xx into `NitroHttpStatusCodeException` is a Dart-side
policy decision driven by `throwOnStatusCode`.

`HybridException` is reserved for programming errors: malformed blob, unknown
instance key, wrong role, engine not configured.

The envelope also gives failures somewhere to carry partial information — a
timeout that still knows its DNS and connect timings.

### 4.3 Streams are module-global broadcast, not per-instance

The generated C++ bridge holds a file-level static port registry **per stream
name**, and the registration function ignores the instance id:

```cpp
static _NitroStreamPorts g_ports_chunks;   // one static per stream NAME

void nitro_http_register_chunks_stream(int64_t instanceId, int64_t dart_port) {
    g_ports_chunks.add(dart_port);         // instanceId unused
}
```

`emit_*` then fans out to every registered port, mallocing a separate copy per
port.

**Consequences:**

- Per-request chunk streams do not exist. A `Stream<RawChunk>` getter on a
  per-request instance would receive *every* request's chunks.
- A second subscriber means a second copy per emit — and, for a zero-copy
  struct, two Dart views over one native payload, i.e. a double free waiting to
  happen.

**Therefore:** there are exactly three module-level streams — `chunks`, `events`,
`wsFrames` — each item tagged with a `requestId` or `socketId`, and the Dart
runtime holds **exactly one** subscription per stream for the whole process.
`NativeStreamDemux.instance` and `NativeWsFrameDemux.instance` are singletons for
that reason, not for convenience; constructing a second one registers a second
port and duplicates delivery.

Backpressure is `Backpressure.bufferDrop`, never `block`: `block` would stall the
emitting thread, which is the `curl_multi` loop, which would stall every other
transfer on that client. Explicit credits (§6) replace it, and because native
never emits beyond the granted credit, the drop ring provably never drops a body
byte. Progress and drain events remain intentionally lossy; the terminal 100 %
progress value is synthesized from the completion path instead.

### 4.4 No callbacks anywhere in the spec

Function-typed parameters are backed by **one `NativeCallable` slot per
(method, parameter)**, replaced whenever the method is called again. Two
concurrent requests passing progress callbacks to the same method would have the
second silently clobber the first's callback.

**Therefore:** zero callbacks in the spec. Progress, upload-drain notifications
and every other out-of-band signal travel on the `events` stream tagged by
`requestId`. The public `onSendProgress` / `onReceiveProgress` callbacks are
served from that demultiplexed stream; they never cross the FFI boundary as
function pointers.

---

## 5. Payload ownership: the ack protocol

This is the subtlest thing in the codebase. Read it before touching
`ChunkArena`, `DeferredPayloads`, `NativeStreamDemux`, or anything that calls
`grantCredit`.

### 5.1 The problem

`RawChunk` is declared `@HybridStruct(zeroCopy: ['bytes'])`. Per emit, the
generated bridge mallocs a small struct **shell** holding
`{ pointer, length, requestId, kind, aux }` and posts that shell's address to
each registered port. On the Dart side the generated proxy holds a
`NativeFinalizer` that calls `nitro_http_release_RawChunk`, and it reads the
payload lazily:

```dart
Uint8List get bytes => _native.ref.bytes.asTypedList(_native.ref.bytesLength);
```

`nitro_http_release_RawChunk` frees **only the shell**. The payload buffer stays
owned by native, and there is no generated signal that tells native when Dart is
finished reading it.

Both naive answers are wrong:

- **Free the payload right after emitting.** The Dart proxy's `bytes` getter then
  reads freed memory. It will usually appear to work, because the allocator has
  not reused the block yet — which is exactly what makes this class of bug
  expensive.
- **Never free it.** A 100 MB download leaks 100 MB.

### 5.2 The protocol

Every emitted payload carries a monotonically increasing per-task sequence
number, and Dart tells native how many payloads it has finished with.

1. **Native tags and tracks.** `RequestTask::emitChunk` allocates the payload,
   assigns it `seq = emittedSeq_++`, hands ownership to `ChunkArena::track(seq,
   blob)`, and then emits the struct.
2. **Dart copies first, always.** `NativeStreamDemux._onChunk` is the *only*
   subscriber. Its first statement copies the bytes:

   ```dart
   final event = ChunkEvent(
     requestId: raw.requestId,
     kind: raw.kind,
     aux: raw.aux,
     bytes: Uint8List.fromList(raw.bytes),   // COPY FIRST
   );
   ```

   Only then is the `ChunkEvent` pushed into the per-request controller. So for
   this codebase, **received == copied**; no chunk is ever visible to a consumer
   as a view over native memory.
3. **Dart counts and acks.** The runner increments `received` once per chunk it
   observes — data, done and error chunks all count — and passes that cumulative
   count as the third argument of every credit call:
   `grantCredit(requestId, chunkCount, ackedChunks)`.
4. **Native frees on the ack.** `RequestTask::grantCredit` runs on the loop
   thread, adds the credits, and calls `arena_.ack(ackedChunks)`, which frees
   every tracked payload with `seq < ackedChunks`.

The credit call is therefore doing two jobs at once — flow control *and* memory
reclamation — which is deliberate: it means the ack rides on a call that already
has to happen, with no extra FFI crossing per chunk.

### 5.3 Why it is sound

The claim is: *if native frees payload `s`, no Dart code will ever read it.*

- Native only frees `s` when it sees `ackedChunks > s`.
- `ackedChunks` is the runner's `received` counter, which is incremented only
  after the demux has already constructed the `ChunkEvent` for that chunk.
- Constructing the `ChunkEvent` copies the bytes.
- Nothing downstream of the demux ever holds `raw.bytes`; only the copy escapes.

So `ackedChunks > s` implies payload `s` was copied, and a copied payload is one
Dart provably no longer reads.

The off-by-one convention that makes `seq < ackedChunks` correct: `seq` is
0-based and `ackedChunks` is a count, so `seq < ackedChunks` names exactly the
first `ackedChunks` emitted payloads. **Both sides must count the same events.**
Native increments `emittedSeq_` once per emit including the terminal `done` /
`error` chunk; Dart increments `received` once per chunk including the terminal
one. Changing either side to skip terminal chunks silently shifts the window and
leaks (or, worse, frees early) exactly one payload per request.

`ChunkArena::ack` is idempotent and tolerant of repeated or out-of-order acks,
because a retried grant or a duplicate terminal call must not be a fault.

### 5.4 The teardown hazard

`Dart_PostCObject_DL` returning `true` means the message **reached the port**,
not that the Dart isolate **processed** it. That gap is where a straightforward
implementation dies:

```
loop thread                            Dart isolate
───────────                            ────────────
emit chunk 0..N-1  ──────────────────►  (queued, not yet processed)
emit terminal chunk ─────────────────►  (queued)
destroy RequestTask
  └─ ChunkArena::releaseAll()
                                        processes chunk 0
                                        reads proxy.bytes  ← FREED MEMORY
```

The window is widest on the **streamed cache-hit path**, where a task is created,
replays an entire body from disk and is destroyed inside a single loop-thread
turn — the isolate may not have run at all yet.

**The fix.** A task tearing down does not free; it `drain()`s every still-tracked
payload out of its arena and hands the batch to `DeferredPayloads`, a
process-global registry keyed by `(PayloadOwner, id)`. `PayloadOwner` exists
because request ids and socket ids come from independent Dart counters and would
otherwise collide.

The bucket is released when the runner sends its **terminal**
`grantCredit(id, 0, received)`, which `RequestRunner._creditedBody.finish()` does
only *after* `await sub?.cancel()` — i.e. after every posted chunk has been
processed and copied. Ordinary acks for an id that native has already retired
also release prefixes, so a long tail is not held hostage waiting for the
terminal call.

`ChunkArena::releaseAll()` is therefore only correct from `resetAll()` (hot
restart, where the isolate holding those views is gone) or from the deferred
registry once a terminal ack has arrived.

### 5.5 The backstop

A caller that takes an `HttpStreamResponse` and never listens to its body never
produces a terminal ack, so its bucket would live forever. `DeferredPayloads`
caps itself at `kMaxBytes` (32 MiB) and `kMaxBuckets` (256) and drops the oldest
bucket when a cap is hit.

That is a genuine use-after-free risk — but *only* for a stream nobody is
reading, which is already a caller bug that leaks the whole transfer. Bounding
the memory is the better trade than growing without limit. `resetAll()` drops
everything unconditionally, because by then the isolate that held those views no
longer exists.

### 5.6 WebSocket frames use the same protocol

`RawWsFrame` is `@HybridStruct(zeroCopy: ['payload'])` with the identical
problem. `WsSession` owns a `ChunkArena`, `NativeWsFrameDemux` copies each
payload before emitting, and `NitroWebSocket` acks through
`wsGrantCredit(count, acked)` with `PayloadOwner::Socket`. `NitroWebSocket._finish`
sends `grantCredit(0, _received)` for exactly the reason the request runner does.

### 5.7 What zero-copy actually buys

Dart still makes one copy, in the demux. The saving is the copy that does *not*
happen: without `zeroCopy`, the payload would be encoded into the per-port record
blob on the native side (copy one) and decoded into a Dart list (copy two), with
an extra allocation per registered port. With it, the engine's own buffer is
handed over by pointer and Dart copies once.

The copy in Dart is not a failure to be optimised away later. It is the
mechanism that makes the free provable: handing application code a view with an
unbounded lifetime would make "when is it safe to free?" unanswerable.

---

## 6. The credit loop

Flow control is explicit, app-level, and symmetric.

### 6.1 Download

Constants live in `request_runner.dart`:

| Constant | Value | Role |
|---|---|---|
| `kInitialCredits` | 16 | Size of the outstanding-chunk window |
| `kCreditBatch` | 8 | Top up once the window has drained by this much |
| `kUploadHighWaterMark` | 1 MiB | Pause the Dart upload source above this |

The window is deliberately small. The point of credits is that a slow consumer
closes the TCP window; a large window would just relocate the buffer into the
Dart heap.

- On `onListen`, the runner grants `kInitialCredits`.
- Each data chunk decrements `outstanding`; once
  `outstanding <= kInitialCredits - kCreditBatch`, it tops back up to the full
  window and rides the ack along.
- `topUp()` refuses to grant while `controller.isPaused`. That single line is
  how `StreamSubscription.pause()` reaches the TCP window: no credits, so native
  hits zero, so `WRITEFUNCTION` returns `CURL_WRITEFUNC_PAUSE`, so curl stops
  reading the socket. `onResume` calls `topUp()` again, and the loop thread
  issues `curl_easy_pause(CURLPAUSE_CONT)`.
- `onCancel` cancels the transfer outright rather than draining into a discarded
  stream.

`_drain` — used only when `throwOnStatusCode` fires on a streamed response, so
the error body can be attached to the exception — runs the same protocol in
miniature: grant the window, ack one per chunk, terminal-ack on the way out.

### 6.2 Upload

`_UploadPump` feeds `feedUploadChunk`, which returns the bytes currently buffered
in `BodyPipe`. Above `kUploadHighWaterMark` the pump pauses its Dart source and
waits for an `uploadDrain` event on the `events` stream. `finishUpload` closes
the pipe at end of stream; `failUpload` propagates a source error so the transfer
aborts instead of hanging with a half-sent body.

`BodyPipe` is the only object touched by two threads without going through the
engine inbox: `feedUpload` runs on the Dart isolate thread while
`READFUNCTION` drains on the loop thread. It carries its own mutex for exactly
that reason.

---

## 7. Threading contract

| Thread | Owns | May call |
|---|---|---|
| Dart isolate (UI) | Dart objects, credit accounting, `received` counters | Sync FFI entry points only. Each validates, copies, enqueues, wakes and returns in sub-microsecond time. |
| Engine loop (one per `CurlEngine`) | Every easy/multi handle after `add_handle`; `ChunkArena`s | `curl_*` freely, including `curl_easy_pause`; emits stream items; posts results |
| WebSocket receive (one per `WsSession`) | That socket's easy handle | `curl_easy_recv`/`send`; sends from other threads serialize on `ioMtx_` |
| Cache IO (one per `HttpCache`) | Index and body files | Filesystem, eviction; never touches curl |

**The rule that matters most: once `curl_multi_add_handle` has been called, only
the loop thread may touch that handle.** `curl_easy_pause` from another thread is
undefined behaviour that manifests as rare, unreproducible crashes. Every
cross-thread request — submit, cancel, credit grant, unpause, cookie op,
shutdown — is pushed onto a mutex-guarded deque and woken with
`curl_multi_wakeup`, then executed on the loop thread. A debug-build thread-id
assertion guards every curl-touching method.

Cookie operations need a handle bound to the client's `curl_share` but not
attached to a transfer, so each engine keeps one **parked easy handle** and runs
cookie ops as inbox ops on the loop thread.

`curl_global_init` runs once under `std::call_once`. `curl_global_cleanup` is
deliberately never called: it is unsafe with concurrent reload and would leak a
few KB at most on library unload.

### Hot restart

The Dart isolate is torn down without cancelling subscriptions while native
threads keep running. Two mechanisms cover it:

1. `Dart_PostCObject_DL` returns `false` for a dead port. Every post and emit
   site checks it: free the blob that would have been transferred, drop the port
   from the registry, and cancel the associated transfer.
2. `NitroHttp.reset()` calls `resetNative()` → `EngineRegistry::resetAll()`:
   drain every engine's inbox with a shutdown op, abort transfers, join threads,
   flush cookie jars, drop every deferred payload bucket, and bump the
   generation counter so a straggling emit is discarded rather than delivered.

---

## 8. Memory ownership, exhaustively

| Direction | Payload | Allocated by | Freed by | Lifetime rule |
|---|---|---|---|---|
| Dart → C++ | `@zeroCopy Uint8List` parameter | Dart (pinned) | Dart arena | **Valid only during the call.** Native must copy synchronously. |
| Dart → C++ | record parameter | Dart arena | Dart arena on return | Same: deep-copy before returning. `PendingRequest` exists for this. |
| C++ → Dart | native-async result blob | `malloc` in the engine | Dart `unpack` → `nitro_http_nitro_free` | If `Dart_PostCObject_DL` returns false, the poster frees immediately. |
| C++ → Dart | stream record item (`RawEvent`) | `toNativeBuffer()` per emit | generated bridge, per port | One buffer per registered port. |
| C++ → Dart | zero-copy struct **shell** | generated bridge per emit | Dart `NativeFinalizer` → `nitro_http_release_RawChunk` | Shell only. Says nothing about the payload. |
| C++ → Dart | zero-copy struct **payload** | `malloc` in the engine | `ChunkArena::ack` on the credit ack, or `DeferredPayloads` after teardown | §5. Native must not touch the buffer after emit. |
| C++ internal | curl-owned strings (`CURLINFO_*`) | libcurl | libcurl | Copy into the record **before** `curl_easy_cleanup`. |
| C++ internal | `BodyPipe` ring | engine | engine on task teardown | Bounded; back-pressures via `CURL_READFUNC_PAUSE`. |

The arena rule in rows one and two is a hard native contract: Nitro releases the
parameter arena when the registering call returns, so `sendBuffered`,
`startStreamed`, `prefetch` and `wsConnect` must deep-copy the request record and
the body bytes synchronously. A C++ test copies, tears the arena down, and then
verifies the copies.

---

## 9. File map

### 9.1 `src/engine/` — namespace `nitrohttp`

| File | Responsibility |
|---|---|
| `Common.{h,cpp}` | Shared vocabulary: `Blob`, monotonic clock, `EngineError`, the `CURLcode` → `RawErrorKind` table, and the two Dart seams (`StreamSink`, post hook) that make the engine testable without a Dart VM |
| `EngineRegistry.{h,cpp}` | Instance-key parsing, `RoleHandle`, the client/socket maps, `curl_global_init` once, the shared cache, the prefetch engine, generation counter, `resetAll()` |
| `CurlEngine.{h,cpp}` | One client: owned `curl_multi`, loop thread, `curl_share` (cookies, DNS, TLS session tickets), inbox, submit/cancel/credit/cookie/shutdown ops |
| `ClientConfig.{h,cpp}` | Decoded `RawClientConfig`; applies options to each easy handle |
| `ContentDecoder.{h,cpp}` | Streaming gzip / deflate / br / zstd, chained right-to-left, with a 512 MiB output ceiling. `CURLOPT_HTTP_CONTENT_DECODING` is off and this owns the job instead, because curl aborts an unknown coding with `CURLE_BAD_CONTENT_ENCODING` where `dart:io` passes it through — and because "which codings work" must not depend on how the local libcurl was built |
| `RequestTask.{h,cpp}` | One transfer: handle setup, the four curl callbacks, buffered vs streamed vs prefetch modes, cache read/write-back, exactly-once completion |
| `BodyPipe.{h,cpp}` | Bounded upload ring with the pause/resume protocol; the one two-thread object outside the inbox |
| `ChunkArena.{h,cpp}` | Zero-copy payload lifetime: `track` / `ack` / `drain` / `releaseAll` (§5) |
| `DeferredPayloads.{h,cpp}` | Process-global registry holding un-acked payloads after a task dies, with byte and bucket caps (§5.4, §5.5) |
| `Wire.{h,cpp}` | The record encode/decode work the generator does not hand us |
| `DartPost.{h,cpp}` | `Dart_PostCObject_DL` wrappers, dead-port handling, blob lifetime, exactly-once accounting |
| `CertStore.{h,cpp}` | Per-platform trust: SecTrust on Apple, `CURLSSLOPT_NATIVE_CA` on Windows, a normalised PEM blob on Android, bundle probing on Linux; plus mTLS material, SPKI pins and TLS version bounds |
| `CookieBridge.{h,cpp}` | Cookie engine access through the parked easy handle, as inbox ops |
| `HttpCache.{h,cpp}` | RFC 9111 subset: index, freshness, revalidation, LRU eviction, `CacheWriter` |
| `WsSession.{h,cpp}` | WebSockets: `CURLOPT_CONNECT_ONLY` handshake, then hand-written RFC 6455 framing, masking, reassembly, ping/pong and close over `curl_easy_send`/`recv` |
| `EngineUnity.cpp` | Unity translation unit `#include`ing every engine `.cpp`. Apple only — podspecs glob `Classes/**` and cannot reach `../src`, so one forwarder per Apple location includes this instead of maintaining a forwarder per source |
| `mozilla_roots.inc` | Generated Mozilla CA bundle backing `RootCaSource.bundled` |

CMake platforms compile the individual sources with
`NITRO_HTTP_ENGINE_SEPARATE_TUS` defined (better incremental builds and
parallelism); Apple compiles the unity TU.

### 9.2 `lib/src/`

| File | Responsibility |
|---|---|
| `nitro_http.native.dart` | **The Nitro spec.** Enums, records, zero-copy structs, the module class, the three streams. Changing it forces a regenerate + relink and a rebuild on every platform |
| `nitro_http.g.dart`, `generated/` | Generated bindings — never hand-edited |
| `api/settings.dart` | `ClientSettings` and every sub-settings value type; sealed proxy, DNS and redirect variants; URL resolution and query merging |
| `api/request.dart` | `HttpMethod`, `HttpVersion`, `HttpExpectedBody`, `CacheMode`, `RequestOptions`, `HttpRequest` |
| `api/headers.dart` | Ordered, case-insensitive multimap with a lower-cased index; redacting `toString` |
| `api/body.dart` | Sealed `HttpBody`, multipart items, the lazy multipart composer and its length computation, form encoding, content-type sniffing |
| `api/response.dart` | `HttpTimings`, `ResponseMetadata`, sealed `HttpResponse`, charset-aware lenient text decoding |
| `api/exceptions.dart` | Sealed `NitroHttpException` hierarchy and its message composition |
| `api/cancel_token.dart` | One-shot cooperative cancellation |
| `api/progress.dart` | `ProgressCallback`, `ProgressSnapshot` |
| `api/interceptor.dart` | `Interceptor`, `InterceptorResult`, the sealed outcome types, and `InterceptorChain` (forward in, reverse out) |
| `api/retry_interceptor.dart` | `RetryPolicy` (a pure value type) and `RetryInterceptor` (which carries it). Split so a hook can never re-enter the chain it is suspended in |
| `api/cookies.dart` | Pure-Dart `Cookie`, `Set-Cookie` parsing, `CookieJar`, `InMemoryCookieJar` |
| `api/cache.dart` | `HttpCacheConfig`, `CacheStats` |
| `api/client.dart` | `NitroHttpClient`: verbs, the single `request()` funnel, interceptors + retry, cookies, lifecycle |
| `api/fetch.dart` | `NitroHttp` statics (capabilities, cache, prefetch, hot-restart reset) and the `fetch()` one-liner |
| `api/websocket.dart` | `NitroWebSocket`, implementing `package:web_socket`'s `WebSocket` |
| `internal/instance_keys.dart` | Id allocation and key formatting for the three roles |
| `internal/raw_mapping.dart` | Typed ↔ `Raw*` translation in both directions, body encoding, and the exhaustive `RawErrorKind` → exception table |
| `internal/request_runner.dart` | `RequestExecutor` / `StreamDemux` seams, the native implementations, the single-subscriber demux, `RequestRunner`, `_UploadPump` |
| `internal/ws_runner.dart` | `WsExecutor` / `WsFrameDemux` seams and their native implementations |
| `internal/engine_runner.dart` | `EngineExecutor` seam for the `engine` role, plus `runPrefetch` |
| `compat/http_compat.dart` | `NitroHttpCompatClient extends http.BaseClient` |

### 9.3 Test seams

The whole orchestration is unit-testable with no native library because three
interfaces are injectable:

- `NitroHttpClient({RequestExecutor? executor, StreamDemux? demux})` — passing
  either bypasses all FFI.
- `NitroWebSocket.connect(..., WsExecutor? executor, WsFrameDemux? demux)`.
- `NitroHttp.overrideEngineExecutorForTesting(EngineExecutor?)`.

On the C++ side, `NITRO_HTTP_TESTING` swaps `Dart_PostCObject_DL` for an
in-process hook and `installStreamSink` replaces the emit path, so a test can
assert on the exact bytes the bridge would have posted.

---

## 10. Invariant checklist

Break one of these and the failure will be intermittent, load-dependent and
extremely annoying to bisect. In rough order of how expensive a mistake is:

1. **Exactly one subscriber per module-global stream.** `NativeStreamDemux` and
   `NativeWsFrameDemux` are process singletons. A second subscription duplicates
   delivery and hands two Dart views the same native payload.
2. **Copy before you count.** The demux copies `raw.bytes` before constructing
   the `ChunkEvent`, and the runner counts a chunk only once that event exists.
   Reordering those two steps makes every ack a lie.
3. **Both sides count the same chunks.** `emittedSeq_` and `received` must
   include terminal chunks, or `seq < ackedChunks` slips by one.
4. **A dying task defers, it does not free.** `~RequestTask` drains into
   `DeferredPayloads`; only a terminal ack or `resetAll()` may release those.
5. **Exactly one post per accepted request.** Cancellation, shutdown and
   preparation failure all post. A silent path hangs a Dart `Future` forever.
6. **Only the loop thread touches an attached handle.** Everything else goes
   through the inbox.
7. **Deep-copy parameters synchronously.** The Nitro arena dies when the
   registering call returns.
8. **Copy `CURLINFO_*` strings before `curl_easy_cleanup`.** They are owned by
   the handle.
9. **A streamed request body is never replayed.** The retry loop refuses rather
   than sending a truncated second attempt.
10. **Hand-written build logic stays out of `src/CMakeLists.txt`.** It lives in
    `src/deps.cmake` and `src/engine.cmake`, outside every section
    `nitrogen link` rewrites.
