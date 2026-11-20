/// Local-file access for multipart file parts where there is no `dart:io`
/// (the browser). Kept out of `body.dart` so the public API stays WASM-safe.
library;

/// A browser cannot read a local path; this matches what `dart:io`'s `File`
/// throws there.
Stream<List<int>> openFileRead(String path) =>
    throw UnsupportedError('Multipart file parts need dart:io: $path');

/// See [openFileRead].
Future<int?> fileLengthOrNull(String path) =>
    throw UnsupportedError('Multipart file parts need dart:io: $path');
