// Many parallel requests to one TLS host: nitro_http over HTTP/2, nitro_http
// held to HTTP/1.1, and dart:io (which has no HTTP/2 client), fetching the
// same URL. The server is tool/bench_native/h2tls on the Mac (the loopback, or
// an emulator's host link), or any public HTTP/2 host over the device's own
// network. Keep the counts low against a host that is not yours.
//
// Run by integration_test/remote_tls_test.dart, and by
// `--dart-define=BENCH_PROBE=remote --dart-define=BENCH_REMOTE_URL=<url>` in
// place of the benchmark. A host given as an IP address is the self-signed
// bench server, and only then is verification off.
import 'dart:io';

import 'package:nitro_http/nitro_http.dart';

const int _burst = int.fromEnvironment('BENCH_REMOTE_BURST', defaultValue: 64);
const int _bursts = int.fromEnvironment(
  'BENCH_REMOTE_BURSTS',
  defaultValue: 20,
);
const int _serial = int.fromEnvironment(
  'BENCH_REMOTE_SERIAL',
  defaultValue: 300,
);

/// An address to resolve the host to in nitro_http, so it takes the route
/// another client took. Empty leaves resolution to the platform.
const String _pin = String.fromEnvironment('BENCH_REMOTE_PIN');
const int _coldBursts = int.fromEnvironment(
  'BENCH_REMOTE_COLD_BURSTS',
  defaultValue: 5,
);

/// Completes with whether the request had to open a connection, when the
/// client can tell.
typedef _Get = Future<bool> Function();

double _p50(List<int> micros) {
  micros.sort();
  return micros[micros.length ~/ 2] / 1000;
}

/// A GET through dart:io that fails on a status outside 2xx, so an error page
/// is never timed as a download. Completes with the peer address.
Future<String> _ioGet(HttpClient client, Uri url) async {
  final response = await (await client.getUrl(url)).close();
  final peer = response.connectionInfo?.remoteAddress.address ?? '?';
  await response.drain<void>();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('status ${response.statusCode}', uri: url);
  }
  return peer;
}

/// [names] starting from a different one each round, so no client always
/// runs first or last within a round.
List<String> _rotated(List<String> names, int round) => [
  for (var i = 0; i < names.length; i++) names[(i + round) % names.length],
];

/// One line per client: negotiated protocol, median serial GET and median
/// time for a burst of [_burst] GETs of [resource], in milliseconds.
Future<List<String>> runRemoteTlsProbe(String resource) async {
  final url = Uri.parse(resource);
  final selfSigned = InternetAddress.tryParse(url.host) != null;
  NitroHttpClient nitro(HttpVersionPref pref) => NitroHttpClient(
    settings: ClientSettings(
      httpVersionPref: pref,
      dnsSettings: _pin.isEmpty
          ? const DnsSettings.system()
          : DnsSettings.static({
              url.host: [_pin],
            }, port: url.port),
      tlsSettings: selfSigned
          ? const TlsSettings.insecure()
          : const TlsSettings(),
      poolSettings: const PoolSettings(
        maxConnections: _burst,
        maxConnectionsPerHost: _burst,
      ),
    ),
  );
  HttpClient io() {
    final client = HttpClient();
    if (selfSigned) client.badCertificateCallback = (_, _, _) => true;
    return client;
  }

  const names = ['nitro_http auto', 'nitro_http http11Only', 'dart:io'];
  final protocols = <String, String>{};
  final serial = {for (final name in names) name: <int>[]};
  final bursts = {for (final name in names) name: <int>[]};
  final opened = {for (final name in names) name: 0};
  final watch = Stopwatch();

  final h2 = nitro(HttpVersionPref.auto);
  final h1 = nitro(HttpVersionPref.http11Only);
  final dartIo = io();
  try {
    final clients = <String, _Get>{
      names[0]: () async =>
          (await h2.requestBytes(HttpMethod.get, resource)).timings.tls >
          Duration.zero,
      names[1]: () async =>
          (await h1.requestBytes(HttpMethod.get, resource)).timings.tls >
          Duration.zero,
      names[2]: () async {
        await _ioGet(dartIo, url);
        return false;
      },
    };
    // Protocol and peer address: two clients on different address families
    // are on different routes, and their times are not comparable.
    for (final (name, client) in [(names[0], h2), (names[1], h1)]) {
      final first = await client.requestBytes(HttpMethod.get, resource);
      protocols[name] = '${first.version.label} ${first.primaryIp}';
    }
    protocols[names[2]] = 'HTTP/1.1 ${await _ioGet(dartIo, url)}';

    // Open every connection a burst will use before anything is timed.
    for (final get in clients.values) {
      for (var i = 0; i < 2; i++) {
        await Future.wait([for (var j = 0; j < _burst; j++) get()]);
      }
    }

    // One round per client in turn, so a change in the link lands on all
    // three.
    for (var i = 0; i < _bursts; i++) {
      for (final name in _rotated(names, i)) {
        watch
          ..reset()
          ..start();
        final results = await Future.wait([
          for (var j = 0; j < _burst; j++) clients[name]!(),
        ]);
        watch.stop();
        bursts[name]!.add(watch.elapsedMicroseconds);
        opened[name] = opened[name]! + results.where((isNew) => isNew).length;
      }
    }
    for (var i = 0; i < _serial; i++) {
      for (final name in _rotated(names, i)) {
        watch
          ..reset()
          ..start();
        await clients[name]!();
        watch.stop();
        serial[name]!.add(watch.elapsedMicroseconds);
      }
    }
  } finally {
    h2.dispose();
    h1.dispose();
    dartIo.close(force: true);
  }

  // The same burst from a client that has no connection yet, as at app launch.
  final cold = {for (final name in names) name: <int>[]};
  for (var i = 0; i < _coldBursts; i++) {
    for (final name in _rotated(names, i)) {
      final fresh = name == names[2]
          ? null
          : nitro(
              name == names[0]
                  ? HttpVersionPref.auto
                  : HttpVersionPref.http11Only,
            );
      final freshIo = io();
      try {
        watch
          ..reset()
          ..start();
        await Future.wait([
          for (var j = 0; j < _burst; j++)
            fresh != null
                ? fresh.requestBytes(HttpMethod.get, resource)
                : _ioGet(freshIo, url),
        ]);
        watch.stop();
        cold[name]!.add(watch.elapsedMicroseconds);
      } finally {
        fresh?.dispose();
        freshIo.close(force: true);
      }
    }
  }
  return <String>[
    'REMOTE_TLS $resource | serial GET p50 ms | burst of $_burst p50 (min) '
        'ms | connections opened in $_bursts bursts | cold burst p50 ms | '
        'round n starts with client n mod ${names.length}',
    for (final name in names)
      '${name.padRight(22)} ${protocols[name]!} | '
          '${_p50(serial[name]!).toStringAsFixed(3)} | '
          '${_p50(bursts[name]!).toStringAsFixed(2)} '
          '(${(bursts[name]!.first / 1000).toStringAsFixed(2)}) | '
          '${name == names[2] ? '-' : opened[name]} | '
          '${_p50(cold[name]!).toStringAsFixed(2)}',
  ];
}
