/// The one place that knows every [HttpSender] implementation.
///
/// Two ways to get a sender, deliberately, because the console and the
/// benchmark want opposite things from connection state:
///
/// * [senderFor] hands back a shared, cached instance, so successive sends
///   through the console reuse a pooled connection — which is part of what the
///   console is demonstrating.
/// * [createSender] builds a fresh one the caller owns and closes, so a
///   benchmark run does not inherit whatever the console warmed up a minute
///   ago and make its first iteration measure something different from the
///   rest.
///
/// [capabilitiesFor] is separate from both because the console greys out
/// controls before anything has been sent. Reading capabilities off a live
/// client would mean constructing one — which, for the two native libraries,
/// means loading a native library just to ask a question about a `bool`.
library;

import 'dart:async';

import '../http_library.dart';
import '../http_sender.dart';
import 'dart_io_sender.dart';
import 'dio_sender.dart';
import 'nitro_sender.dart';
import 'package_http_sender.dart';
import 'rhttp_sender.dart';

/// The shared instances handed out by [senderFor].
final Map<HttpLibrary, HttpSender> _cache = <HttpLibrary, HttpSender>{};

/// A shared sender for [library], created on first use.
///
/// The registry owns it: do not [HttpSender.close] what this returns, or the
/// next caller gets a closed client. Use [createSender] when you need one of
/// your own.
HttpSender senderFor(HttpLibrary library) =>
    _cache.putIfAbsent(library, () => createSender(library));

/// A new, independent sender for [library]. The caller owns it and must
/// [HttpSender.close] it.
///
/// Construction never throws and never touches the network or a native library,
/// so this is safe to call for all five even on a machine where nothing is
/// built. A missing engine surfaces on the first `send` as a `FailedSend` with
/// [SendFailureKind.unsupported] and the loader's own message.
HttpSender createSender(HttpLibrary library) => switch (library) {
  HttpLibrary.nitroHttp => NitroSender(),
  HttpLibrary.dartIo => DartIoSender(),
  HttpLibrary.packageHttp => PackageHttpSender(),
  HttpLibrary.dio => DioSender(),
  HttpLibrary.rhttp => RhttpSender(),
};

/// What [library] can do, without constructing anything.
///
/// A pure lookup over the `const` capability values each sender also returns
/// from `HttpSender.capabilities`, so a greyed-out control can never disagree
/// with what the sender would actually have done.
SenderCapabilities capabilitiesFor(HttpLibrary library) => switch (library) {
  HttpLibrary.nitroHttp => nitroCapabilities,
  HttpLibrary.dartIo => dartIoCapabilities,
  HttpLibrary.packageHttp => packageHttpCapabilities,
  HttpLibrary.dio => dioCapabilities,
  HttpLibrary.rhttp => rhttpCapabilities,
};

/// Closes and forgets every sender [senderFor] cached.
///
/// Instances from [createSender] are untouched — they were never the
/// registry's to close.
Future<void> closeAll() async {
  final open = _cache.values.toList(growable: false);
  _cache.clear();
  for (final sender in open) {
    // One client failing to shut down must not strand the other four, and app
    // teardown is the last place that should throw.
    try {
      await sender.close();
    } on Object {
      continue;
    }
  }
}
