/// A cleartext HTTP/2 (h2c, prior-knowledge) test server, for the benchmark's
/// protocol A/B only.
///
/// The main [LocalServer] is HTTP/1.1 (dart:io has no HTTP/2 server), so a run
/// against it never exercises the multiplexing that `nitro_http` (libcurl) and
/// `rhttp` (reqwest) actually use in production — their burst numbers measure
/// HTTP/1.1 connection racing instead. This server speaks h2 directly over a
/// plaintext socket via `package:http2`; a client set to
/// `HttpVersionPref.http2Only` (→ `CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE`) sends
/// the HTTP/2 preface immediately and multiplexes a burst over one connection.
///
/// Deliberately minimal: it serves only the routes the latency/throughput
/// scenarios need — `GET /bytes/<n>` and `POST /upload`. The redirect/slow/echo
/// routes behind the `mixed` scenario are not reimplemented here, so `mixed`
/// stays on the HTTP/1.1 server. The byte generator is shared with
/// [LocalServer] so a body is identical on both protocols.
///
/// The pure-Dart clients (`dart:io`, `package:http`, `dio`) have no HTTP/2
/// client, so an h2 run is inherently `nitro_http` vs `rhttp` — which is the
/// only meaningful h2 comparison anyway.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http2/http2.dart';

import 'local_server.dart' show deterministicByteStream;

/// An h2c server on an ephemeral loopback port.
final class H2TestServer {
  H2TestServer._(this._socket);

  final ServerSocket _socket;

  /// Binds on `127.0.0.1:0` and starts accepting h2 connections.
  static Future<H2TestServer> start() async {
    final socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      // Match LocalServer: a burst opens many connections before multiplexing
      // is confirmed, and a short listen queue would answer the overflow with
      // ECONNREFUSED and look like a client defect.
      backlog: 1024,
    );
    final server = H2TestServer._(socket);
    socket.listen(server._accept);
    return server;
  }

  /// `http://127.0.0.1:<port>` with no trailing slash. The scheme is `http`
  /// because this is cleartext h2c, reached via prior knowledge rather than TLS
  /// ALPN.
  String get baseUrl => 'http://127.0.0.1:${_socket.port}';

  /// Stops accepting and closes the listening socket.
  Future<void> stop() => _socket.close();

  void _accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final connection = ServerTransportConnection.viaSocket(socket);
    connection.incomingStreams.listen(
      _handle,
      onError: (_) {}, // a client that hangs up mid-burst is not a server error
      cancelOnError: false,
    );
  }

  void _handle(ServerTransportStream stream) {
    String method = 'GET';
    String path = '/';
    var received = 0;
    stream.incomingMessages.listen(
      (message) {
        if (message is HeadersStreamMessage) {
          for (final header in message.headers) {
            final name = ascii.decode(header.name);
            if (name == ':method') {
              method = ascii.decode(header.value);
            } else if (name == ':path') {
              path = ascii.decode(header.value);
            }
          }
        } else if (message is DataStreamMessage) {
          received += message.bytes.length;
        }
      },
      onError: (_) {},
      cancelOnError: false,
      onDone: () => unawaited(_respond(stream, method, path, received)),
    );
  }

  Future<void> _respond(
    ServerTransportStream stream,
    String method,
    String path,
    int received,
  ) async {
    final bytesMatch = RegExp(r'^/bytes/(\d+)$').firstMatch(path);
    try {
      if (method == 'GET' && bytesMatch != null) {
        final length = int.parse(bytesMatch.group(1)!);
        stream.sendHeaders(<Header>[
          Header.ascii(':status', '200'),
          Header.ascii('content-type', 'application/octet-stream'),
          Header.ascii('content-length', '$length'),
        ]);
        if (length == 0) {
          stream.sendData(const <int>[], endStream: true);
          return;
        }
        var sent = 0;
        await for (final page in deterministicByteStream(length)) {
          sent += page.length;
          stream.sendData(page, endStream: sent >= length);
        }
        return;
      }
      if (method == 'POST' && path == '/upload') {
        final body = utf8.encode('{"received":$received}');
        stream.sendHeaders(<Header>[
          Header.ascii(':status', '200'),
          Header.ascii('content-type', 'application/json'),
          Header.ascii('content-length', '${body.length}'),
        ]);
        stream.sendData(body, endStream: true);
        return;
      }
      stream.sendHeaders(<Header>[
        Header.ascii(':status', '404'),
        Header.ascii('content-length', '0'),
      ], endStream: true);
    } on StateError {
      // The stream was reset by the peer (cancelled request) between the done
      // callback and the send — nothing to deliver to.
    }
  }
}

/// [H2TestServer] running in its own isolate, mirroring `IsolatedServer` so the
/// h2 and h1 servers are measured under identical isolation.
final class IsolatedH2Server {
  IsolatedH2Server._(this.baseUrl, this._control);

  /// `http://127.0.0.1:<port>`, served from the child isolate.
  final String baseUrl;
  final SendPort _control;

  /// Spawns the isolate, starts an [H2TestServer] inside it, and returns once
  /// it is bound.
  static Future<IsolatedH2Server> start() async {
    final handshake = ReceivePort();
    await Isolate.spawn(_main, handshake.sendPort);
    final ready = await handshake.first as List<Object?>;
    handshake.close();
    return IsolatedH2Server._(ready[0]! as String, ready[1]! as SendPort);
  }

  /// Stops the server and lets the isolate exit.
  Future<void> stop() async {
    final done = ReceivePort();
    _control.send(done.sendPort);
    await done.first;
    done.close();
  }

  static Future<void> _main(SendPort reply) async {
    final server = await H2TestServer.start();
    final control = ReceivePort();
    reply.send(<Object?>[server.baseUrl, control.sendPort]);
    final ack = await control.first as SendPort;
    await server.stop();
    control.close();
    ack.send(null);
  }
}
