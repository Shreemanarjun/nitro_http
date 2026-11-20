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
  final h2 = nitro(HttpVersionPref.auto);
  final h1 = nitro(HttpVersionPref.http11Only);
  final dartIo = HttpClient();
  if (selfSigned) dartIo.badCertificateCallback = (_, _, _) => true;

  final clients = <String, _Get>{
    'nitro_http auto': () async =>
        (await h2.requestBytes(HttpMethod.get, resource)).timings.tls >
        Duration.zero,
    'nitro_http http11Only': () async =>
        (await h1.requestBytes(HttpMethod.get, resource)).timings.tls >
        Duration.zero,
    'dart:io': () async {
      final response = await (await dartIo.getUrl(url)).close();
      await response.drain<void>();
      return false;
    },
  };
  // Protocol and peer address: two clients on different address families are
  // on different routes, and their times are not comparable.
  final first = {
    'nitro_http auto': await h2.requestBytes(HttpMethod.get, resource),
    'nitro_http http11Only': await h1.requestBytes(HttpMethod.get, resource),
  };
  final ioResponse = await (await dartIo.getUrl(url)).close();
  final ioPeer = ioResponse.connectionInfo?.remoteAddress.address ?? '?';
  await ioResponse.drain<void>();
  final protocols = <String, String>{
    for (final entry in first.entries)
      entry.key: '${entry.value.version.label} ${entry.value.primaryIp}',
    'dart:io': 'HTTP/1.1 $ioPeer',
  };

  // Open every connection a burst will use before anything is timed.
  for (final get in clients.values) {
    for (var i = 0; i < 2; i++) {
      await Future.wait([for (var j = 0; j < _burst; j++) get()]);
    }
  }

  final serial = {for (final name in clients.keys) name: <int>[]};
  final bursts = {for (final name in clients.keys) name: <int>[]};
  final opened = {for (final name in clients.keys) name: 0};
  final watch = Stopwatch();
  // One round per client in turn, so a change in the link lands on all three.
  for (var i = 0; i < _bursts; i++) {
    for (final entry in clients.entries) {
      watch
        ..reset()
        ..start();
      final results = await Future.wait([
        for (var j = 0; j < _burst; j++) entry.value(),
      ]);
      watch.stop();
      bursts[entry.key]!.add(watch.elapsedMicroseconds);
      opened[entry.key] =
          opened[entry.key]! + results.where((isNew) => isNew).length;
    }
  }
  for (var i = 0; i < _serial; i++) {
    for (final entry in clients.entries) {
      watch
        ..reset()
        ..start();
      await entry.value();
      watch.stop();
      serial[entry.key]!.add(watch.elapsedMicroseconds);
    }
  }

  h2.dispose();
  h1.dispose();
  dartIo.close(force: true);

  // The same burst from a client that has no connection yet, as at app launch.
  final cold = {for (final name in clients.keys) name: <int>[]};
  for (var i = 0; i < _coldBursts; i++) {
    for (final name in clients.keys) {
      final fresh = name == 'dart:io'
          ? null
          : nitro(
              name.endsWith('auto')
                  ? HttpVersionPref.auto
                  : HttpVersionPref.http11Only,
            );
      final freshIo = HttpClient();
      if (selfSigned) freshIo.badCertificateCallback = (_, _, _) => true;
      Future<void> get() async {
        if (fresh != null) {
          await fresh.requestBytes(HttpMethod.get, resource);
        } else {
          final response = await (await freshIo.getUrl(url)).close();
          await response.drain<void>();
        }
      }

      watch
        ..reset()
        ..start();
      await Future.wait([for (var j = 0; j < _burst; j++) get()]);
      watch.stop();
      cold[name]!.add(watch.elapsedMicroseconds);
      fresh?.dispose();
      freshIo.close(force: true);
    }
  }
  return <String>[
    'REMOTE_TLS $resource | serial GET p50 ms | burst of $_burst p50 (min) '
        'ms | connections opened in $_bursts bursts | cold burst p50 ms',
    for (final name in clients.keys)
      '${name.padRight(22)} ${protocols[name]!} | '
          '${_p50(serial[name]!).toStringAsFixed(3)} | '
          '${_p50(bursts[name]!).toStringAsFixed(2)} '
          '(${(bursts[name]!.first / 1000).toStringAsFixed(2)}) | '
          '${name == 'dart:io' ? '-' : opened[name]} | '
          '${_p50(cold[name]!).toStringAsFixed(2)}',
  ];
}
