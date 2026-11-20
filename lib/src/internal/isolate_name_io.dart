/// The current isolate's debug name, where `dart:isolate` exists.
library;

import 'dart:isolate';

/// `Isolate.current.debugName`.
String? currentIsolateName() => Isolate.current.debugName;
