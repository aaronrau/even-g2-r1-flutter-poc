import 'dart:convert';
import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/protocol/g2_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('G2 GATT layout', () {
    test(
      'qualifies control and audio characteristics under firmware services',
      () {
        expect(G2Ids.advertisedService, endsWith('72e0000'));
        expect(G2Ids.controlService, endsWith('72e5450'));
        expect(G2Ids.audioService, endsWith('72e6450'));
        expect(G2Ids.write, endsWith('72e5401'));
        expect(G2Ids.notify, endsWith('72e5402'));
        expect(G2Ids.audioNotify, endsWith('72e6402'));
      },
    );
  });

  group('G2 CRC and transport', () {
    test('matches the standard CRC-16 check vector', () {
      expect(g2Crc16(ascii.encode('123456789')), 0x29b1);
    });

    test('builds the expected empty reserved packet', () {
      final packets = G2Transport.buildPackets(
        syncId: 0,
        serviceId: G2Ids.serviceEvenHub,
        payload: const <int>[],
        reserveFlag: true,
      );

      expect(packets.single, <int>[
        0xaa,
        0x21,
        0,
        2,
        1,
        1,
        0xe0,
        0x20,
        0xff,
        0xff,
      ]);
    });

    test('splits payloads at 236 bytes and reassembles them', () {
      final payload = Uint8List.fromList(
        List<int>.generate(237, (index) => index & 0xff),
      );
      final packets = G2Transport.buildPackets(
        syncId: 7,
        serviceId: G2Ids.serviceEvenHub,
        payload: payload,
      );
      final receiver = G2ReceiveAssembler();

      expect(packets, hasLength(2));
      expect(receiver.add(packets.first, 'R'), isNull);
      final result = receiver.add(packets.last, 'R');
      expect(result, isNotNull);
      expect(result!.serviceId, G2Ids.serviceEvenHub);
      expect(result.crcValid, isTrue);
      expect(result.payload, payload);
    });
  });

  group('G2 command subset', () {
    test('encodes Android authentication with phone type 4', () {
      final protocol = G2Protocol();

      expect(protocol.authentication(isIos: false), <int>[
        0x08,
        0x04,
        0x10,
        0x00,
        0x1a,
        0x04,
        0x08,
        0x01,
        0x10,
        0x04,
      ]);
    });

    test('encodes iOS authentication with phone type 3', () {
      final protocol = G2Protocol();

      expect(protocol.authentication(isIos: true).last, 0x03);
    });

    test('creates and updates the single POC text container', () {
      final protocol = G2Protocol();
      final create = protocol.createTextPage('hello');
      final update = protocol.updateText('world');

      expect(create, containsAllInOrder(utf8.encode('hello')));
      expect(create, containsAllInOrder(utf8.encode('evt-0')));
      expect(update, containsAllInOrder(utf8.encode('world')));
    });

    test('clears text with the firmware-compatible newline update', () {
      final protocol = G2Protocol();
      final command = protocol.clearText();
      final fields = ProtoReader(command).readFields();
      final update = ProtoReader(fields[9]! as Uint8List).readFields();

      expect(update[4], 1);
      expect(utf8.decode(update[5]! as Uint8List), '\n');
    });

    test('encodes the immediate native foreground exit response', () {
      final protocol = G2Protocol();
      final command = protocol.shutdownPage();
      final fields = ProtoReader(command).readFields();
      final shutdown = ProtoReader(fields[11]! as Uint8List).readFields();

      expect(fields[1], 9);
      expect(shutdown[1], 0);
    });

    test('encodes the official private Terminal mode and host status', () {
      final protocol = G2Protocol();
      final modeCommand = protocol.terminalModeSync(terminal: true);
      final modeOuter = ProtoReader(modeCommand).readFields();
      final mode = ProtoReader(modeOuter[3]! as Uint8List).readFields();

      expect(G2Ids.serviceTerminal, 0x30);
      expect(modeOuter[1], 1);
      expect(mode[1], 2);
      expect(mode[2], 0);

      final pcCommand = protocol.terminalPcStatusSync(connected: true);
      final pcOuter = ProtoReader(pcCommand).readFields();
      final pcStatus = ProtoReader(pcOuter[4]! as Uint8List).readFields();

      expect(pcOuter[1], 2);
      expect(pcStatus[1], 2);
      expect(pcStatus[2], 0);

      final sessionCommand = protocol.terminalSessionList(
        hostId: 7,
        sessionId: 9,
        title: 'POC',
      );
      final sessionOuter = ProtoReader(sessionCommand).readFields();
      final sessions = ProtoReader(sessionOuter[16]! as Uint8List).readFields();
      final item = ProtoReader(sessions[3]! as Uint8List).readFields();

      expect(sessionOuter[1], 8);
      expect(sessions[1], 7);
      expect(sessions[2], 9);
      expect(item[1], 9);
      expect(utf8.decode(item[2]! as Uint8List), 'POC');
      expect(item[3], 2);

      final agentCommand = protocol.terminalAgentStatus(state: 2, sessionId: 9);
      final agentOuter = ProtoReader(agentCommand).readFields();
      final agent = ProtoReader(agentOuter[6]! as Uint8List).readFields();

      expect(agentOuter[1], 4);
      expect(agent[1], 2);
      expect(agent[2], 9);
    });

    test('encodes the G2 ring connection command', () {
      final protocol = G2Protocol();
      final command = protocol.ringConnectInfo(
        connect: true,
        ringMac: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );
      final fields = ProtoReader(command).readFields();
      final ring = ProtoReader(fields[5]! as Uint8List).readFields();

      expect(fields[1], 6);
      expect(ring[1], 1);
      expect(ring[2], Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]));
    });

    test('encodes and decodes G2 battery status', () {
      final protocol = G2Protocol();
      expect(
        protocol.deviceInfoRequest(),
        Uint8List.fromList(const <int>[
          0x08,
          0x02,
          0x10,
          0x00,
          0x22,
          0x02,
          0x08,
          0x01,
        ]),
      );

      final status = decodeG2BatteryStatus(
        Uint8List.fromList(const <int>[
          0x08,
          0x02,
          0x22,
          0x04,
          0x60,
          0x52,
          0x68,
          0x01,
        ]),
      );
      expect(status?.level, 82);
      expect(status?.charging, isTrue);
    });

    test('encodes the G2 ring release command for direct input mode', () {
      final protocol = G2Protocol();
      final command = protocol.ringConnectInfo(
        connect: false,
        ringMac: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );
      final fields = ProtoReader(command).readFields();
      final ring = ProtoReader(fields[5]! as Uint8List).readFields();

      expect(fields[1], 6);
      expect(ring[1], 0);
      expect(ring[2], Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]));
    });

    test('decodes an R1 gesture forwarded by EvenHub', () {
      final systemEvent = ProtoWriter()
        ..writeInt32(1, 3)
        ..writeInt32(2, 2);
      final deviceEvent = ProtoWriter()
        ..writeMessage(3, systemEvent.takeBytes());
      final payload = ProtoWriter()
        ..writeInt32(1, 2)
        ..writeMessage(13, deviceEvent.takeBytes());

      final event = decodeG2Gesture(payload.takeBytes());
      expect(event?.name, 'double_tap');
      expect(event?.isFromR1, isTrue);
    });

    test('decodes an omitted default enum as an R1 single tap', () {
      final systemEvent = ProtoWriter()..writeInt32(2, 2);
      final deviceEvent = ProtoWriter()
        ..writeMessage(3, systemEvent.takeBytes());
      final payload = ProtoWriter()
        ..writeInt32(1, 2)
        ..writeMessage(13, deviceEvent.takeBytes());

      final event = decodeG2Gesture(payload.takeBytes());
      expect(event?.name, 'single_tap');
      expect(event?.isFromR1, isTrue);
      expect(event?.typeWasOmitted, isTrue);
    });

    test('decodes swipe events from the evt-0 text capture container', () {
      G2GestureEvent? decodeTextEvent(int type) {
        final textEvent = ProtoWriter()
          ..writeString(2, 'evt-0')
          ..writeInt32(3, type);
        final deviceEvent = ProtoWriter()
          ..writeMessage(2, textEvent.takeBytes());
        final payload = ProtoWriter()
          ..writeInt32(1, 2)
          ..writeMessage(13, deviceEvent.takeBytes());
        return decodeG2Gesture(payload.takeBytes());
      }

      final up = decodeTextEvent(1);
      final down = decodeTextEvent(2);

      expect(up?.name, 'swipe_up');
      expect(up?.path, G2GesturePath.textEvent);
      expect(up?.source, isNull);
      expect(down?.name, 'swipe_down');
      expect(down?.path, G2GesturePath.textEvent);
    });

    test('builds and sends a firmware-compatible test drawing', () {
      final protocol = G2Protocol();
      final bitmap = G2Bitmap.testPattern(width: 8, height: 4);
      final header = ByteData.sublistView(bitmap);
      final rebuild = protocol.rebuildPageWithImage(content: 'drawing');
      final update = protocol.updateImage(bitmap);

      expect(bitmap.take(2), <int>[0x42, 0x4d]);
      expect(header.getInt32(18, Endian.little), 8);
      expect(header.getInt32(22, Endian.little), 4);
      expect(header.getUint16(28, Endian.little), 4);
      expect(rebuild, containsAllInOrder(utf8.encode('img-10')));
      expect(update, containsAllInOrder(bitmap));
    });

    test('builds the blank visualizer page with gesture text below audio', () {
      final protocol = G2Protocol();
      final command = protocol.rebuildAudioVisualizerPage();
      final outer = ProtoReader(command).readFields();
      final page = ProtoReader(outer[7]! as Uint8List).readFields();
      final gesture = ProtoReader(page[3]! as Uint8List).readFields();
      final image = ProtoReader(page[4]! as Uint8List).readFields();

      expect(outer[1], 7);
      expect(page[1], 3);
      expect(gesture[1], 16);
      expect(gesture[2], G2Protocol.visualizerGestureY);
      expect(gesture[3], 544);
      expect(gesture[4], 64);
      expect(utf8.decode(gesture[12]! as Uint8List), isEmpty);
      expect(image[1], 16);
      expect(image[2], 12);
      expect(image[3], G2Protocol.visualizerWaveformWidth);
      expect(image[4], G2Protocol.visualizerWaveformHeight);
    });

    test('renders a one-fragment LC3 activity waveform', () {
      final quiet = G2Bitmap.audioActivityWaveform(
        levels: List<int>.filled(64, 0),
        width: G2Protocol.visualizerWaveformWidth,
        height: G2Protocol.visualizerWaveformHeight,
      );
      final active = G2Bitmap.audioActivityWaveform(
        levels: List<int>.generate(64, (index) => index * 4),
        width: G2Protocol.visualizerWaveformWidth,
        height: G2Protocol.visualizerWaveformHeight,
      );
      final protocol = G2Protocol();
      final packets = protocol.frame(
        G2Ids.serviceEvenHub,
        protocol.updateImage(active),
        reserveFlag: true,
      );
      final header = ByteData.sublistView(active);

      expect(active.length, lessThan(1800));
      expect(packets.length, lessThan(10));
      expect(
        header.getInt32(18, Endian.little),
        G2Protocol.visualizerWaveformWidth,
      );
      expect(
        header.getInt32(22, Endian.little),
        G2Protocol.visualizerWaveformHeight,
      );
      expect(active, isNot(orderedEquals(quiet)));
      expect(active.skip(118).where((byte) => byte != 0).length, lessThan(300));
    });

    test('extracts global gain from a 40-byte G2 LC3 frame', () {
      const expectedGain = 178;
      final frame = Uint8List(40);
      for (var index = 0; index < 8; index++) {
        if ((expectedGain >> index) & 1 == 1) {
          final bit = 9 + index;
          frame[frame.length - 1 - bit ~/ 8] |= 1 << (bit & 7);
        }
      }

      expect(G2AudioAnalysis.globalGainIndex(frame), expectedGain);
      expect(G2AudioAnalysis.globalGainIndex(Uint8List(39)), isNull);
    });

    test('includes the remaining firmware session initialization commands', () {
      final protocol = G2Protocol();

      expect(protocol.uiSettingsQuery(), isNotEmpty);
      expect(protocol.dashboardInit(), isNotEmpty);
      expect(protocol.disableHeyEven(), isNotEmpty);
    });
  });
}
