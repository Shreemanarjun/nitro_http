/// Makes backpressure visible.
///
/// `/drip` sends a fixed number of chunks with a delay between them and no
/// `Content-Length`, so the body arrives progressively. Turning on the slow
/// consumer pauses the subscription after every chunk, which withholds native
/// credits — the transfer stalls instead of piling up in the Dart heap, and the
/// plot flattens while the "paused" lamp is lit.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';

import '../server/local_server.dart';
import '../widgets/panels.dart';

/// One point of the received-bytes plot.
final class TransferSample {
  /// Creates a sample.
  const TransferSample({required this.elapsed, required this.bytes});

  /// Milliseconds since the transfer started.
  final int elapsed;

  /// Total bytes received by that point.
  final int bytes;
}

/// The streaming screen.
class StreamingTab extends StatefulWidget {
  /// Creates the screen against [server].
  const StreamingTab({required this.server, super.key});

  /// The local server the stream is read from.
  final LocalServer server;

  @override
  State<StreamingTab> createState() => _StreamingTabState();
}

class _StreamingTabState extends State<StreamingTab> {
  static const int _chunks = 64;
  static const int _serverDelayMs = 50;
  static const Duration _consumerDelay = Duration(milliseconds: 200);

  NitroHttpClient? _client;
  Object? _error;

  StreamSubscription<List<int>>? _subscription;
  final Stopwatch _clock = Stopwatch();
  final List<TransferSample> _samples = [];

  bool _slowConsumer = true;
  bool _running = false;
  bool _paused = false;
  bool _done = false;
  int _bytes = 0;
  int _chunkCount = 0;
  int? _contentLength;
  int _statusCode = 0;
  HttpVersion _version = HttpVersion.unknown;

  @override
  void dispose() {
    _subscription?.cancel();
    _client?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _samples.clear();
      _bytes = 0;
      _chunkCount = 0;
      _contentLength = null;
      _statusCode = 0;
      _version = HttpVersion.unknown;
      _done = false;
      _paused = false;
      _running = true;
    });

    _clock
      ..reset()
      ..start();

    try {
      final client = _client ??= NitroHttpClient(
        settings: ClientSettings(baseUrl: widget.server.baseUrl),
      );
      final response = await client.requestStream(
        HttpMethod.get,
        '/drip/$_chunks/$_serverDelayMs',
      );
      if (!mounted) return;
      setState(() {
        _statusCode = response.statusCode;
        _version = response.version;
        _contentLength = response.contentLength;
      });

      _subscription = response.body.listen(
        _onChunk,
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _error = error;
            _running = false;
          });
        },
        onDone: () {
          _clock.stop();
          if (!mounted) return;
          setState(() {
            _running = false;
            _done = true;
            _paused = false;
          });
        },
        cancelOnError: true,
      );
    } on Object catch (error) {
      _clock.stop();
      if (!mounted) return;
      setState(() {
        _error = error;
        _running = false;
      });
    }
  }

  void _onChunk(List<int> chunk) {
    _bytes += chunk.length;
    _chunkCount++;
    _samples.add(
      TransferSample(elapsed: _clock.elapsedMilliseconds, bytes: _bytes),
    );

    if (_slowConsumer) {
      // `pause(resumeSignal)` is the honest way to model a slow consumer: the
      // subscription really is paused, so the runner stops granting credits and
      // the engine stops reading the socket.
      final subscription = _subscription;
      if (subscription != null) {
        subscription.pause(Future<void>.delayed(_consumerDelay));
        _paused = true;
        Future<void>.delayed(_consumerDelay, () {
          if (mounted) setState(() => _paused = false);
        });
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _cancel() async {
    await _subscription?.cancel();
    _subscription = null;
    _clock.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _paused = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final expectedBytes = _chunks * defaultDripChunkBytes;
    return ListView(
      children: [
        SectionCard(
          title: 'GET /drip/$_chunks/$_serverDelayMs',
          trailing: _PausedLamp(paused: _paused),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$_chunks chunks of ${defaultDripChunkBytes ~/ 1024} KiB, '
                '${_serverDelayMs}ms apart, chunked (no Content-Length). '
                'The slow consumer waits ${_consumerDelay.inMilliseconds}ms per '
                'chunk, which is slower than the server produces them.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Slow consumer (pause after every chunk)'),
                value: _slowConsumer,
                onChanged: _running
                    ? null
                    : (value) => setState(() => _slowConsumer = value),
              ),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _running ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Stream'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _running ? _cancel : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null)
          EngineErrorCard(
            action: 'stream a response body',
            error: _error!,
            onRetry: () => setState(() => _error = null),
          ),
        SectionCard(
          title: 'Progress',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: _bytes == 0 ? null : (_bytes / expectedBytes).clamp(0, 1),
              ),
              const SizedBox(height: 12),
              KeyValueTable(
                rows: [
                  ('status', _statusCode == 0 ? '—' : '$_statusCode'),
                  ('version', _version.label),
                  (
                    'content-length',
                    _contentLength == null ? 'chunked' : '$_contentLength',
                  ),
                  ('chunks received', '$_chunkCount / $_chunks'),
                  ('bytes received', '$_bytes / $expectedBytes'),
                  ('elapsed', '${_clock.elapsedMilliseconds} ms'),
                  ('state', _stateLabel),
                  (
                    'throughput',
                    _clock.elapsedMilliseconds == 0
                        ? '—'
                        : '${(_bytes / 1024 / (_clock.elapsedMilliseconds / 1000)).toStringAsFixed(0)} KiB/s',
                  ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Bytes received over time',
          child: SizedBox(
            height: 180,
            child: CustomPaint(
              painter: _TransferPlotPainter(
                samples: _samples,
                lineColor: Theme.of(context).colorScheme.primary,
                gridColor: Theme.of(context).colorScheme.outlineVariant,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }

  String get _stateLabel {
    if (_error != null) return 'failed';
    if (_done) return 'complete';
    if (_paused) return 'paused (credits withheld)';
    if (_running) return 'receiving';
    return 'idle';
  }
}

class _PausedLamp extends StatelessWidget {
  const _PausedLamp({required this.paused});

  final bool paused;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: paused ? scheme.error : scheme.outlineVariant,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          paused ? 'paused' : 'flowing',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

/// Plots cumulative received bytes against elapsed time.
///
/// A flat run in the line is a stalled transfer, which is exactly what a paused
/// subscription should produce.
class _TransferPlotPainter extends CustomPainter {
  const _TransferPlotPainter({
    required this.samples,
    required this.lineColor,
    required this.gridColor,
  });

  final List<TransferSample> samples;
  final Color lineColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (samples.length < 2) return;

    final maxTime = samples.last.elapsed == 0 ? 1 : samples.last.elapsed;
    final maxBytes = samples.last.bytes == 0 ? 1 : samples.last.bytes;

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
      final x = size.width * sample.elapsed / maxTime;
      final y = size.height - size.height * sample.bytes / maxBytes;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_TransferPlotPainter old) =>
      old.samples.length != samples.length ||
      old.lineColor != lineColor ||
      old.gridColor != gridColor;
}
