/// Fallback for a platform with neither `dart:ffi` nor `dart:js_interop`.
library;

import 'engine_runner.dart';

EngineExecutor defaultEngineExecutor() =>
    throw UnsupportedError('nitro_http has no engine for this platform');
