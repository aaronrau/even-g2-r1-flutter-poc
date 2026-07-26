import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/protocol/r1_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('R1Protocol', () {
    test('builds the official PairAuth command', () {
      final frame = R1Protocol.pairAuth(serialId: 1);

      expect(frame, <int>[
        0x00,
        0xf1,
        0x9b,
        0xde,
        0x96,
        0x64,
        0x01,
        0x64,
        0x01,
        0x00,
        0x00,
        0x00,
        0x08,
        0x0d,
        0x00,
        0xd8,
        0xb5,
        0x01,
      ]);
    });

    test('builds the official framed advStart command', () {
      final frame = R1Protocol.advStart(
        glassesMac: Uint8List.fromList(const <int>[
          0xe4,
          0x94,
          0x67,
          0x46,
          0x73,
          0x87,
        ]),
        serialId: 1,
      );

      expect(frame, <int>[
        0x00,
        0x29,
        0x83,
        0xe8,
        0x11,
        0x64,
        0x01,
        0x64,
        0x01,
        0x00,
        0x00,
        0x00,
        0x0a,
        0x12,
        0x00,
        0x1f,
        0x3e,
        0xe4,
        0x94,
        0x67,
        0x46,
        0x73,
        0x87,
      ]);
    });

    test('builds the direct TouchPad reporting command', () {
      final frame = R1Protocol.touchSwitch(enabled: true, serialId: 7);
      final decoded = R1Protocol.decode(frame);

      expect(decoded, isNotNull);
      expect(decoded!.command, 1);
      expect(decoded.module, 0);
      expect(decoded.subCommand, 7);
      expect(decoded.subCommandName, 'touch_switch');
      expect(decoded.serialId, 7);
      expect(decoded.data, Uint8List.fromList(<int>[1]));
      expect(decoded.checksumsValid, isTrue);
    });

    test('builds the TouchPad status query', () {
      final frame = R1Protocol.touchStatus(serialId: 8);
      final decoded = R1Protocol.decode(frame);

      expect(decoded, isNotNull);
      expect(decoded!.command, 1);
      expect(decoded.module, 0);
      expect(decoded.subCommand, 6);
      expect(decoded.subCommandName, 'touch_status');
      expect(decoded.serialId, 8);
      expect(decoded.statusType, 'notify');
      expect(decoded.statusMethod, 'get');
      expect(decoded.data, isEmpty);
      expect(decoded.checksumsValid, isTrue);
    });

    test('builds the read-only device-status query', () {
      final query = R1Protocol.decode(R1Protocol.deviceStatus(serialId: 9));

      expect(query, isNotNull);
      expect(query!.subCommand, 1);
      expect(query.statusMethod, 'get');
      expect(query.data, isEmpty);
      expect(query.checksumsValid, isTrue);
    });

    test('decodes battery from a hardware device-status response', () {
      final frame = R1Protocol.decode(
        Uint8List.fromList(const <int>[
          0x00,
          0xcf,
          0x0d,
          0xfe,
          0x72,
          0x64,
          0x01,
          0x64,
          0x03,
          0x00,
          0x03,
          0x00,
          0x01,
          0x13,
          0x00,
          0x60,
          0xad,
          0x59,
          0x02,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
        ]),
      );

      expect(frame, isNotNull);
      expect(frame!.transferCrcValid, isTrue);
      expect(frame.subCommandName, 'device_status');
      expect(decodeR1DeviceStatusBattery(frame), 89);
    });

    test('rejects a malformed glasses MAC', () {
      expect(
        () => R1Protocol.advStart(
          glassesMac: Uint8List.fromList(const <int>[1, 2, 3]),
          serialId: 1,
        ),
        throwsArgumentError,
      );
    });

    test('uses a changing serial id in both checksums', () {
      final mac = Uint8List.fromList(const <int>[
        0xe4,
        0x94,
        0x67,
        0x46,
        0x73,
        0x87,
      ]);
      final first = R1Protocol.advStart(glassesMac: mac, serialId: 1);
      final second = R1Protocol.advStart(glassesMac: mac, serialId: 2);

      expect(first, isNot(second));
      expect(second[8], 2);
      expect(second.sublist(0, 5), <int>[0x00, 0xc5, 0xa8, 0xd9, 0xa9]);
      expect(second.sublist(15, 17), <int>[0x3a, 0xdd]);
    });

    test('builds and decodes the official system-time command', () {
      final time = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
      final encoded = R1Protocol.systemTime(time: time, serialId: 3);
      final decoded = R1Protocol.decode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.checksumsValid, isTrue);
      expect(decoded.serialId, 3);
      expect(decoded.subCommand, 5);
      expect(decoded.status, 2);
      expect(decoded.statusMethod, 'set');
      expect(decoded.data.length, 12);
      expect(decoded.data.sublist(0, 6), <int>[0, 0, 0xe8, 0x03, 0, 0]);
    });

    test('reports a damaged framed checksum', () {
      final frame = R1Protocol.pairAuth(serialId: 1);
      frame[frame.length - 1] ^= 0xff;

      final decoded = R1Protocol.decode(frame);
      expect(decoded, isNotNull);
      expect(decoded!.checksumsValid, isFalse);
    });
  });
}
