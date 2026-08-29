/// Fallback for a platform with neither `dart:ffi` nor `dart:js_interop`.
library;

import '../api/settings.dart';
import 'request_runner.dart';

RequestExecutor defaultExecutor(int clientId, ClientSettings settings) =>
    throw UnsupportedError('nitro_http has no executor for this platform');

StreamDemux get defaultDemux =>
    throw UnsupportedError('nitro_http has no executor for this platform');
