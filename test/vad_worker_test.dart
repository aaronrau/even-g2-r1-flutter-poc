import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/audio/vad_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finalizes speech one second after the last VAD detection', () {
    expect(vadTranscriptionDelay, const Duration(seconds: 1));
  });

  test('retains the five-second speech pre-roll', () {
    expect(vadPreRollDuration, const Duration(seconds: 5));
  });

  test('clears the completed turn before buffering the next turn', () {
    final buffer = VadPreRollBuffer(maximumBytes: 8)
      ..add(Uint8List.fromList(<int>[1, 2, 3, 4]));

    expect(buffer.clear(), 4);
    expect(buffer.sizeBytes, 0);
    expect(buffer.chunks, isEmpty);

    buffer.add(Uint8List.fromList(<int>[5, 6]));
    expect(buffer.sizeBytes, 2);
    expect(buffer.chunks.single, <int>[5, 6]);
  });
}
