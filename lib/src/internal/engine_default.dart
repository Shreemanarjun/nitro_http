/// Picks the engine executor for the platform being compiled for.
library;

export 'engine_stub.dart'
    if (dart.library.ffi) 'engine_native.dart'
    if (dart.library.js_interop) 'engine_web.dart'
    show defaultEngineExecutor;
