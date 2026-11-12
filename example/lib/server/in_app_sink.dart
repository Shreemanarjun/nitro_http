/// The benchmark's upload sink for a target that cannot run a second process.
///
/// `tool/bench_native/sink/sink.c`, in the app: it reads the request head,
/// discards exactly Content-Length bytes with blocking `recv` into one reused
/// megabyte of native memory, and answers 200. It runs on its own isolate and
/// allocates nothing per upload, so the client under test does not share an
/// event loop or a garbage collector's workload with it.
///
/// One request is served at a time, start to finish, and a connection is
/// expected to wait for its answer before sending again. The upload scenarios
/// do both.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

final DynamicLibrary _libc = DynamicLibrary.process();

final _socket = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, Int32),
      int Function(int, int, int)
    >('socket');
final _bind = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Uint32),
      int Function(int, Pointer<Uint8>, int)
    >('bind');
final _getsockname = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, Pointer<Uint8>, Pointer<Uint32>)
    >('getsockname');
final _listen = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'listen',
    );
final _accept = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, Pointer<Uint8>, Pointer<Uint32>)
    >('accept');
final _setsockopt = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, Int32, Pointer<Int32>, Uint32),
      int Function(int, int, int, Pointer<Int32>, int)
    >('setsockopt');
final _poll = _libc
    .lookupFunction<
      Int32 Function(Pointer<_PollFd>, Size, Int32),
      int Function(Pointer<_PollFd>, int, int)
    >('poll');
final _recv = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size, Int32),
      int Function(int, Pointer<Uint8>, int, int)
    >('recv');
final _send = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size, Int32),
      int Function(int, Pointer<Uint8>, int, int)
    >('send');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);

final bool _darwin = Platform.isIOS || Platform.isMacOS;

const int _pollIn = 1;
const int _bufferBytes = 1 << 20;
const int _maxConnections = 63;

/// A write to a connection the client has closed must fail, not raise SIGPIPE:
/// a socket option on Darwin, a `send` flag on Linux.
final int _sendFlags = _darwin ? 0 : 0x4000; // MSG_NOSIGNAL

/// Starts the sink on a loopback port of the system's choosing and returns its
/// base URL. It runs until the process exits.
Future<String> startInAppSink() async {
  final address = calloc<Uint8>(16);
  final length = calloc<Uint32>()..value = 16;
  try {
    // sockaddr_in for 127.0.0.1, port 0. Darwin leads with a length byte.
    if (_darwin) {
      address[0] = 16;
      address[1] = 2; // AF_INET
    } else {
      address[0] = 2;
    }
    address[4] = 127;
    address[7] = 1;
    final listener = _socket(2, 1 /* SOCK_STREAM */, 0);
    if (listener < 0 ||
        _bind(listener, address, 16) != 0 ||
        _getsockname(listener, address, length) != 0 ||
        _listen(listener, 64) != 0) {
      throw StateError('in-app sink: could not listen on loopback');
    }
    final port = (address[2] << 8) | address[3];
    await Isolate.spawn(_serve, listener);
    return 'http://127.0.0.1:$port';
  } finally {
    calloc
      ..free(address)
      ..free(length);
  }
}

void _serve(int listener) {
  // An isolate's thread starts in a lower scheduling class than the app's main
  // thread, and at that class the sink, not the client, sets the pace.
  if (_darwin) {
    _libc.lookupFunction<Int32 Function(Uint32, Int32), int Function(int, int)>(
      'pthread_set_qos_class_self_np',
    )(0x21 /* QOS_CLASS_USER_INTERACTIVE */, 0);
  }
  final buffer = malloc<Uint8>(_bufferBytes);
  final fds = malloc<_PollFd>(_maxConnections + 1);
  final one = malloc<Int32>()..value = 1;
  final open = <int>[];
  for (;;) {
    (fds + 0).ref
      ..fd = listener
      ..events = _pollIn
      ..revents = 0;
    for (var i = 0; i < open.length; i++) {
      (fds + i + 1).ref
        ..fd = open[i]
        ..events = _pollIn
        ..revents = 0;
    }
    if (_poll(fds, open.length + 1, -1) <= 0) continue;

    final ready = <int>[
      for (var i = 0; i < open.length; i++)
        if ((fds + i + 1).ref.revents != 0) open[i],
    ];
    for (final fd in ready) {
      if (!_answer(fd, buffer)) {
        _close(fd);
        open.remove(fd);
      }
    }

    if ((fds + 0).ref.revents != 0) {
      final fd = _accept(listener, nullptr, nullptr);
      if (fd < 0) continue;
      if (open.length == _maxConnections) {
        _close(fd);
        continue;
      }
      _setsockopt(fd, 6 /* IPPROTO_TCP */, 1 /* TCP_NODELAY */, one, 4);
      if (_darwin) {
        _setsockopt(
          fd,
          0xffff /* SOL_SOCKET */,
          0x1022 /* SO_NOSIGPIPE */,
          one,
          4,
        );
      }
      open.add(fd);
    }
  }
}

final RegExp _contentLength = RegExp(
  r'^content-length:\s*(\d+)',
  multiLine: true,
  caseSensitive: false,
);

/// Reads one request off [fd] and answers it. False once the peer has gone.
bool _answer(int fd, Pointer<Uint8> buffer) {
  // The head is read in small pieces and kept; the body is not kept at all.
  final head = BytesBuilder();
  var headEnd = -1;
  while (headEnd < 0) {
    if (head.length > 64 * 1024) return false;
    final n = _recv(fd, buffer, 4096, 0);
    if (n <= 0) return false;
    head.add(buffer.asTypedList(n));
    headEnd = _blankLine(head.toBytes());
  }
  final bytes = head.toBytes();
  final declared = _contentLength.firstMatch(
    latin1.decode(bytes.sublist(0, headEnd)),
  );
  final length = declared == null ? 0 : int.parse(declared[1]!);

  var remaining = length - (bytes.length - headEnd - 4);
  while (remaining > 0) {
    final n = _recv(
      fd,
      buffer,
      remaining < _bufferBytes ? remaining : _bufferBytes,
      0,
    );
    if (n <= 0) return false;
    remaining -= n;
  }

  final body = '{"bytes":$length}';
  final response = ascii.encode(
    'HTTP/1.1 200 OK\r\n'
    'Content-Type: application/json\r\n'
    'Content-Length: ${body.length}\r\n\r\n$body',
  );
  buffer.asTypedList(response.length).setAll(0, response);
  return _send(fd, buffer, response.length, _sendFlags) == response.length;
}

/// Index of the `\r\n\r\n` that ends a request head, or -1.
int _blankLine(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}
