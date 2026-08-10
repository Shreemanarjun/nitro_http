/// Instance-key allocation for the Nitro multi-instance factory.
///
/// One spec class produces one shared library, so `nitro_http` cannot split
/// roles across spec files without cross-dylib symbol wiring on five platforms.
/// Roles therefore ride on the instance key that the C++ factory parses:
///
/// | Key             | Backing object                                        |
/// |-----------------|-------------------------------------------------------|
/// | `engine`        | process-wide singleton: cache, prefetch, capabilities |
/// | `c:<clientId>`  | one `CurlEngine` — loop thread, pool, cookie jar      |
/// | `ws:<socketId>` | one WebSocket session                                 |
library;

/// Allocates the ids embedded in instance keys, and the request ids that tag
/// every item on the module-global streams.
abstract final class Ids {
  static int _client = 0;
  static int _socket = 0;
  static int _request = 0;

  /// Client ids start at 1; `-1` is reserved natively for the prefetch engine.
  static int nextClient() => ++_client;

  static int nextSocket() => ++_socket;

  /// Request ids are process-global, not per-client, because the `chunks` and
  /// `events` streams are module-global: two clients handing out the same id
  /// would cross-deliver each other's chunks.
  static int nextRequest() => ++_request;

  /// Test-only. Resets the counters so id-dependent assertions are stable.
  static void resetForTesting() {
    _client = 0;
    _socket = 0;
    _request = 0;
  }
}

/// The process-wide engine instance key.
const String kEngineKey = 'engine';

/// The instance key for client [clientId].
String clientKey(int clientId) => 'c:$clientId';

/// The instance key for WebSocket [socketId].
String socketKey(int socketId) => 'ws:$socketId';
