/// The browser has one isolate, the root one, and no `dart:isolate` under
/// dart2wasm; kept apart so `native_attach.dart` stays WASM-safe.
library;

/// Always `'main'`: on the web the only isolate is the root one.
String? currentIsolateName() => 'main';
