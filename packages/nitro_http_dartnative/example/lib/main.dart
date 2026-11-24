import 'package:dartnative/dartnative.dart';
import 'package:nitro_http_dartnative/nitro_http_dartnative.dart';

import 'dartnative_plugin_registrant.dart';

void main() {
  // Keep first: registers the platform bindings and plugin FFI symbols.
  DartNativePluginRegistrant.registerAll();
  runApp(const HomeScreen());
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _client = NitroHttpClient();
  String _result = 'Sending…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _busy = true);
    final watch = Stopwatch()..start();
    try {
      final response = await _client.get('https://example.com');

      _result =
          '${response.request.url} ${response.statusCode} over ${response.version.label}, '
          '${response.bodyBytes.length} bytes in ${watch.elapsedMilliseconds} ms \n${response.timings}';
    } on NitroHttpException catch (e) {
      _result = 'Failed: $e';
    }
    print('nitro_http: $_result');
    setState(() => _busy = false);
  }

  Future<void> _badSSL() async {
    setState(() => _busy = true);
    final watch = Stopwatch()..start();
    try {
      final response = await _client.get('https://badssl.com');
      _result =
          '${response.request.url} ${response.statusCode} over ${response.version.label}, '
          '${response.bodyBytes.length} bytes in ${watch.elapsedMilliseconds} ms \n${response.timings}\n ${response.body.toString()}';
    } on NitroHttpException catch (e) {
      _result = 'Failed: $e';
    }
    print('nitro_http: $_result');
    setState(() => _busy = false);
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('nitro_http')),
      body: SingleChildScrollView(
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_result, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _busy ? null : _fetch,
                child: const Text('GET https://example.com'),
              ),
              ElevatedButton(
                onPressed: _busy ? null : _badSSL,
                child: const Text('GET https://badssl.com'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
