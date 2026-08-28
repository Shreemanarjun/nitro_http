/// Fallback for a platform with neither `dart:ffi` nor `dart:js_interop`.
library;

import 'request_runner.dart';

RequestExecutor defaultExecutor(int clientId) =>
    throw UnsupportedError('nitro_http has no executor for this platform');

StreamDemux get defaultDemux =>
    throw UnsupportedError('nitro_http has no executor for this platform');
