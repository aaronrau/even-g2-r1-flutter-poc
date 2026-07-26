import 'dart:convert';
import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/ble/ble_models.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final manufacturerData = Uint8List.fromList(<int>[
    0x45,
    0x52,
    ...ascii.encode('S200LACA040040'),
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x00,
  ]);

  test('extracts G2 serial and little-endian MAC', () {
    expect(extractG2Serial(manufacturerData), 'S200LACA040040');
    expect(extractG2Mac(manufacturerData), '06:05:04:03:02:01');
  });

  test('groups left and right lens advertisements', () {
    DiscoveredDevice device(String id, String name) => DiscoveredDevice(
      id: id,
      name: name,
      serviceData: const <Uuid, Uint8List>{},
      manufacturerData: manufacturerData,
      rssi: -50,
      serviceUuids: const <Uuid>[],
    );

    final left = G2PairCandidate.fromDevice(
      device('left', 'Even G2_32_L_AAAAAA'),
    );
    final right = device('right', 'Even G2_32_R_BBBBBB');
    final pair = left!.merge(right);

    expect(pair.isComplete, isTrue);
    expect(pair.left!.id, 'left');
    expect(pair.right!.id, 'right');
    expect(pair.leftMac, '06:05:04:03:02:01');
    expect(pair.rightMac, '06:05:04:03:02:01');
  });
}
