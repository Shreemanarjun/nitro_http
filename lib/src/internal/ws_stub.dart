/// Fallback for a platform with neither `dart:ffi` nor `dart:js_interop`.
library;

import 'ws_runner.dart';

WsExecutor defaultWsExecutor(int socketId) =>
    throw UnsupportedError('nitro_http has no WebSocket for this platform');

WsFrameDemux get defaultWsDemux =>
    throw UnsupportedError('nitro_http has no WebSocket for this platform');
