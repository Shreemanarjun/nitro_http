/// Wires the fetch executor to the browser's `BrowserClient`.
///
/// Kept to just this, because `package:http/browser_client.dart` pulls in
/// `dart:js_interop` and so cannot be compiled — or tested — anywhere but the
/// web. All the behaviour lives in `executor_fetch.dart`, which is why that one
/// has tests.
library;

import 'executor_fetch.dart';
import 'fetch_client_web.dart';
import 'request_runner.dart';

/// The executor a client gets in the browser.
RequestExecutor defaultExecutor(int clientId) {
  final client = NitroFetchClient();
  return FetchRequestExecutor(
    client,
    setCredentials: (enabled) => client.withCredentials = enabled,
    timings: resourceTimingFor,
  );
}

/// The demux a client gets in the browser.
StreamDemux get defaultDemux => FetchStreamDemux.instance;
