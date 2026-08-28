/// Picks the executor for the platform being compiled for.
///
/// The native executor imports `dart:ffi`, and a library that does so cannot be
/// compiled for the browser at all — so the choice has to be a conditional
/// import rather than a `kIsWeb` branch, which would still drag `dart:ffi` into
/// the web build.
library;

export 'executor_stub.dart'
    if (dart.library.ffi) 'executor_native.dart'
    if (dart.library.js_interop) 'executor_web.dart'
    show defaultDemux, defaultExecutor;
