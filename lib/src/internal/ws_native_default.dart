/// The engine-backed WebSocket executor, selected on a platform with `dart:ffi`.
library;

import 'ws_runner.dart';

/// The WebSocket executor a caller gets on a native platform.
WsExecutor defaultWsExecutor(int socketId) => NativeWsExecutor(socketId);

/// The frame demux a caller gets on a native platform.
WsFrameDemux get defaultWsDemux => NativeWsFrameDemux.instance;
