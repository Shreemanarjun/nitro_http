// Wire-value decoders, exhaustively.
//
// These map an integer off the FFI boundary onto a Dart enum. They are the one
// place where a native-side change can go unnoticed: a wrong mapping does not
// fail to compile, it silently mislabels a frame. So every documented opcode is
// asserted, and so is the unknown fallback.

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/src/internal/ws_runner.dart';

void main() {
  group('WsOpcode.fromWire', () {
    test('maps every RFC 6455 opcode the engine emits', () {
      expect(WsOpcode.fromWire(0), WsOpcode.continuation);
      expect(WsOpcode.fromWire(1), WsOpcode.text);
      expect(WsOpcode.fromWire(2), WsOpcode.binary);
      expect(WsOpcode.fromWire(8), WsOpcode.close);
      expect(WsOpcode.fromWire(9), WsOpcode.ping);
      expect(WsOpcode.fromWire(10), WsOpcode.pong);
    });

    test('maps the engine-private transport-error code', () {
      // 255 is not an RFC opcode; the engine uses it to surface a socket
      // failure through the same frame stream.
      expect(WsOpcode.fromWire(255), WsOpcode.transportError);
    });

    test('falls back to unknown for anything else', () {
      // A reserved or future opcode must not throw on a user's device.
      for (final wire in [3, 4, 5, 6, 7, 11, 12, 13, 14, 15, 99, -1, 1 << 20]) {
        expect(WsOpcode.fromWire(wire), WsOpcode.unknown, reason: '$wire');
      }
    });

    test('every enum value except unknown round-trips from its wire code', () {
      // Guards against an enum entry being added without a `fromWire` arm.
      const wireOf = <WsOpcode, int>{
        WsOpcode.continuation: 0,
        WsOpcode.text: 1,
        WsOpcode.binary: 2,
        WsOpcode.close: 8,
        WsOpcode.ping: 9,
        WsOpcode.pong: 10,
        WsOpcode.transportError: 255,
      };

      for (final opcode in WsOpcode.values) {
        if (opcode == WsOpcode.unknown) continue;
        expect(
          wireOf[opcode],
          isNotNull,
          reason: '$opcode has no wire code in this test',
        );
        expect(WsOpcode.fromWire(wireOf[opcode]!), opcode);
      }
    });
  });
}
