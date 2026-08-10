/// A WebSocket console against the local `/ws` echo endpoint.
///
/// Framing, masking and the close handshake all run in C++; this screen only
/// drives the public [NitroWebSocket] surface, which is the Dart team's
/// `package:web_socket` interface.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';

import '../server/local_server.dart';
import '../widgets/panels.dart';

/// Direction of a logged frame.
enum LogDirection {
  /// Sent by this app.
  outbound('→'),

  /// Received from the peer.
  inbound('←'),

  /// A local lifecycle note.
  note('•');

  const LogDirection(this.marker);

  /// Prefix shown in the log.
  final String marker;
}

/// One line of the message log.
final class SocketLogEntry {
  /// Creates a log entry stamped with the current time.
  SocketLogEntry(this.direction, this.text) : at = DateTime.now();

  /// Which way the frame went.
  final LogDirection direction;

  /// The rendered payload or note.
  final String text;

  /// When it happened.
  final DateTime at;

  @override
  String toString() {
    final stamp = at.toIso8601String().split('T').last;
    return '$stamp ${direction.marker} $text';
  }
}

/// The WebSocket screen.
class WebSocketTab extends StatefulWidget {
  /// Creates the screen against [server].
  const WebSocketTab({required this.server, super.key});

  /// The local server hosting `/ws`.
  final LocalServer server;

  @override
  State<WebSocketTab> createState() => _WebSocketTabState();
}

class _WebSocketTabState extends State<WebSocketTab> {
  static const List<int> _closeCodes = [1000, 3000, 4001, 4999];

  final TextEditingController _message = TextEditingController(text: 'hello, engine');
  final TextEditingController _closeReason = TextEditingController(text: 'done');
  final List<SocketLogEntry> _log = [];
  final Random _random = Random();

  NitroWebSocket? _socket;
  StreamSubscription<WebSocketEvent>? _events;
  Object? _error;
  bool _connecting = false;
  int _closeCode = 1000;
  String _protocol = '';
  int _handshakeStatus = 0;

  bool get _isOpen => _socket != null;

  @override
  void dispose() {
    _events?.cancel();
    _socket?.close().ignore();
    _message.dispose();
    _closeReason.dispose();
    super.dispose();
  }

  void _append(LogDirection direction, String text) {
    if (!mounted) return;
    setState(() => _log.insert(0, SocketLogEntry(direction, text)));
  }

  Future<void> _connect({bool closeEndpoint = false}) async {
    setState(() {
      _error = null;
      _connecting = true;
    });
    final path = closeEndpoint ? '/ws/close' : '/ws';
    try {
      final socket = await NitroWebSocket.connect(
        widget.server.wsUri(path),
        protocols: closeEndpoint ? null : const ['echo'],
        pingInterval: const Duration(seconds: 10),
      );
      if (!mounted) {
        await socket.close();
        return;
      }
      setState(() {
        _socket = socket;
        _protocol = socket.protocol;
        _handshakeStatus = socket.handshakeStatusCode;
      });
      _append(
        LogDirection.note,
        'connected to $path (HTTP ${socket.handshakeStatusCode}, '
        'protocol "${socket.protocol}")',
      );
      _events = socket.events.listen(_onEvent, onDone: _onClosed);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _onEvent(WebSocketEvent event) {
    switch (event) {
      case TextDataReceived(:final text):
        _append(LogDirection.inbound, 'text (${text.length} chars): $text');
      case BinaryDataReceived(:final data):
        _append(
          LogDirection.inbound,
          'binary (${data.length} bytes): ${_hexPreview(data)}',
        );
      case CloseReceived(:final code, :final reason):
        _append(LogDirection.note, 'closed: code $code, reason "$reason"');
    }
  }

  void _onClosed() {
    _events = null;
    if (!mounted) return;
    setState(() {
      _socket = null;
      _protocol = '';
      _handshakeStatus = 0;
    });
  }

  void _guard(String what, void Function() action) {
    try {
      action();
    } on Object catch (error) {
      _append(LogDirection.note, 'failed to $what: $error');
    }
  }

  void _sendText() {
    final socket = _socket;
    if (socket == null) return;
    final text = _message.text;
    _guard('send text', () {
      socket.sendText(text);
      _append(LogDirection.outbound, 'text (${text.length} chars): $text');
    });
  }

  void _sendBinary() {
    final socket = _socket;
    if (socket == null) return;
    final payload = Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
    _guard('send binary', () {
      socket.sendBytes(payload);
      _append(
        LogDirection.outbound,
        'binary (${payload.length} bytes): ${_hexPreview(payload)}',
      );
    });
  }

  void _sendLarge() {
    final socket = _socket;
    if (socket == null) return;
    // 256 KiB forces the engine to fragment the message and the peer to
    // reassemble it, which is the interesting path.
    final payload = deterministicBytes(256 * 1024);
    _guard('send large binary', () {
      socket.sendBytes(payload);
      _append(
        LogDirection.outbound,
        'binary (${payload.length} bytes, fragmented)',
      );
    });
  }

  void _ping() {
    final socket = _socket;
    if (socket == null) return;
    _guard('ping', () {
      socket.ping(Uint8List.fromList(utf8.encode('probe')));
      _append(LogDirection.outbound, 'ping ("probe")');
    });
  }

  Future<void> _close() async {
    final socket = _socket;
    if (socket == null) return;
    final reason = _closeReason.text;
    _append(LogDirection.outbound, 'close($_closeCode, "$reason")');
    try {
      await socket.close(_closeCode, reason);
    } on Object catch (error) {
      _append(LogDirection.note, 'close failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SectionCard(
          title: 'Connection',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KeyValueTable(
                rows: [
                  ('url', '${widget.server.webSocketUrl}/ws'),
                  ('state', _isOpen ? 'open' : 'closed'),
                  ('handshake', _handshakeStatus == 0 ? '—' : '$_handshakeStatus'),
                  ('protocol', _protocol.isEmpty ? '—' : _protocol),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _connecting || _isOpen ? null : _connect,
                    icon: const Icon(Icons.power),
                    label: const Text('Connect /ws'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _connecting || _isOpen
                        ? null
                        : () => _connect(closeEndpoint: true),
                    icon: const Icon(Icons.report_gmailerrorred),
                    label: const Text('Connect /ws/close'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null)
          EngineErrorCard(
            action: 'open a WebSocket',
            error: _error!,
            onRetry: () => setState(() => _error = null),
          ),
        SectionCard(
          title: 'Send',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _message,
                decoration: const InputDecoration(
                  labelText: 'Text message',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _sendText(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _isOpen ? _sendText : null,
                    child: const Text('Send text'),
                  ),
                  OutlinedButton(
                    onPressed: _isOpen ? _sendBinary : null,
                    child: const Text('Send 16 B binary'),
                  ),
                  OutlinedButton(
                    onPressed: _isOpen ? _sendLarge : null,
                    child: const Text('Send 256 KiB binary'),
                  ),
                  OutlinedButton(
                    onPressed: _isOpen ? _ping : null,
                    child: const Text('Ping'),
                  ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Close',
          child: Row(
            children: [
              DropdownButton<int>(
                value: _closeCode,
                onChanged: (value) =>
                    setState(() => _closeCode = value ?? _closeCode),
                items: [
                  for (final code in _closeCodes)
                    DropdownMenuItem(value: code, child: Text('$code')),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _closeReason,
                  decoration: const InputDecoration(
                    labelText: 'Reason (≤ 123 bytes)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _isOpen ? _close : null,
                child: const Text('Close'),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Log (${_log.length})',
          trailing: TextButton(
            onPressed: _log.isEmpty ? null : () => setState(_log.clear),
            child: const Text('Clear'),
          ),
          child: CodeBlock(
            maxHeight: 300,
            text: _log.map((entry) => '$entry').join('\n'),
          ),
        ),
      ],
    );
  }

  static String _hexPreview(Uint8List bytes) {
    final take = bytes.length > 12 ? 12 : bytes.length;
    final hex = [
      for (var i = 0; i < take; i++)
        bytes[i].toRadixString(16).padLeft(2, '0'),
    ].join(' ');
    return bytes.length > take ? '$hex …' : hex;
  }
}
