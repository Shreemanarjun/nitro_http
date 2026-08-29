/// Picks the WebSocket executor for the platform being compiled for.
library;

export 'ws_stub.dart'
    if (dart.library.ffi) 'ws_native_default.dart'
    if (dart.library.js_interop) 'ws_web.dart'
    show defaultWsDemux, defaultWsExecutor;
