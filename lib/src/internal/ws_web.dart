/// Wires the browser WebSocket executor to `package:web_socket`.
///
/// Kept to just this: the browser implementation pulls in `dart:js_interop` and
/// so cannot be compiled — or tested — anywhere but the web. The behaviour
/// lives in `ws_browser.dart`, which is why that one has tests.
library;

import 'package:web_socket/web_socket.dart' as ws;

import 'ws_browser.dart';
import 'ws_runner.dart';

/// The WebSocket executor a caller gets in the browser.
WsExecutor defaultWsExecutor(int socketId) => BrowserWsExecutor(
  socketId,
  (url, protocols) => ws.WebSocket.connect(url, protocols: protocols),
);

/// The frame demux a caller gets in the browser.
WsFrameDemux get defaultWsDemux => BrowserWsFrameDemux.instance;
