/// Local-file access for multipart file parts, where `dart:io` exists.
library;

import 'dart:io';

/// Streams the file at [path] incrementally, never holding it all in memory.
Stream<List<int>> openFileRead(String path) => File(path).openRead();

/// The size of the file at [path], or `null` if it is missing or unreadable.
Future<int?> fileLengthOrNull(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) return null;
    return await file.length();
  } on FileSystemException {
    return null;
  }
}
