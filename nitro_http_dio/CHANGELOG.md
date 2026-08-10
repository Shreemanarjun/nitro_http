## 0.0.1

First release, alongside `nitro_http` 0.0.1.

### Added

* **`NitroHttpDioAdapter`**, a dio 5.x `HttpClientAdapter` that routes every
  request through `nitro_http`'s native libcurl engine. dio keeps its
  interceptors, transformers, `FormData` and `Response<T>`; the transport
  underneath becomes one C++ engine shared by Android, iOS, macOS, Windows and
  Linux.
* **`Dio.useNitroHttp()`**, for the one-liner `Dio()..useNitroHttp()`.
* **Owned or borrowed clients.** With no `client` the adapter builds one from
  `ClientSettings` and disposes it on `close()`; given a `client` it borrows it
  and leaves it running. `close(force: true)` cancels exactly the transfers this
  adapter started, never a shared client's other work.
* **Always streamed.** The adapter takes the engine's streamed path and hands
  the body stream to dio, so `ResponseType.stream` works and a large download
  is never buffered twice.
* **Duplicate response headers survive.** Headers are flattened with `getAll`,
  so two `Set-Cookie` fields stay two fields instead of being joined with a
  comma that their `Expires` attributes also contain.
* **`cancelFuture` becomes a `CancelToken`**, which aborts a transfer already on
  the wire rather than merely abandoning the future.
* **Per-request cache mode** through `extra['nitroHttp.cacheMode']`, accepting a
  `CacheMode` or its name; an unrecognised value throws instead of being
  ignored.
* **Typed errors.** `NitroHttpException` becomes a `DioException` with the right
  `DioExceptionType` and the original kept as `error`, including failures that
  surface part-way through the response body.

### Known gaps

* **`sendTimeout` has no separate engine deadline.** libcurl times the whole
  transfer, so a stalled upload is caught by the total timeout mapped from
  `receiveTimeout`. `DioExceptionType.sendTimeout` is never produced.
* **dio's interceptors and `nitro_http`'s are separate layers.** dio's run above
  the adapter, the engine's below; neither sees the other's rewrites.
* **No web support**, because the engine is native code.
