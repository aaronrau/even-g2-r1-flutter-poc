import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/audio/vad_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finalizes after 1.75 seconds of total detected silence', () {
    expect(vadDetectorSilenceDuration, const Duration(milliseconds: 500));
    expect(vadTranscriptionDelay, const Duration(milliseconds: 1250));
    expect(vadTotalSilenceDuration, const Duration(milliseconds: 1750));
    expect(
      vadDetectorSilenceDuration + vadTranscriptionDelay,
      vadTotalSilenceDuration,
    );
  });

  test('resumed speech cancels the endpoint tail', () {
    final endpoint = VadEndpointBuffer(
      sampleRate: 16000,
      duration: vadTranscriptionDelay,
    );

    expect(endpoint.begin(8000), isFalse);
    expect(endpoint.add(8000), isFalse);
    expect(endpoint.capturedMilliseconds, 1000);

    endpoint.reset();
    expect(endpoint.isActive, isFalse);
    expect(endpoint.capturedMilliseconds, 0);

    expect(endpoint.begin(8000), isFalse);
    expect(endpoint.add(12000), isTrue);
    expect(endpoint.capturedMilliseconds, 1250);
  });

  test('retains the two-second speech pre-roll', () {
    expect(vadPreRollDuration, const Duration(seconds: 2));
  });

  test('pre-roll retains the newest continuous PCM chunks', () {
    final buffer = VadPreRollBuffer(maximumBytes: 6)
      ..add(Uint8List.fromList(<int>[1, 2]))
      ..add(Uint8List.fromList(<int>[3, 4]))
      ..add(Uint8List.fromList(<int>[5, 6]))
      ..add(Uint8List.fromList(<int>[7, 8]));

    expect(buffer.sizeBytes, 6);
    expect(buffer.chunks.map((chunk) => chunk.toList()), <List<int>>[
      <int>[3, 4],
      <int>[5, 6],
      <int>[7, 8],
    ]);
  });

  test('clears prior-turn history before buffering endpoint-tail PCM', () {
    final buffer = VadPreRollBuffer(maximumBytes: 8)
      ..add(Uint8List.fromList(<int>[1, 2, 3, 4]));

    expect(buffer.clear(), 4);
    expect(buffer.sizeBytes, 0);
    expect(buffer.chunks, isEmpty);

    buffer.add(Uint8List.fromList(<int>[5, 6]));
    expect(buffer.sizeBytes, 2);
    expect(buffer.chunks.single, <int>[5, 6]);
  });

  test('retains only endpoint-tail PCM for the next turn', () {
    final buffer = VadPreRollBuffer(maximumBytes: 8)
      ..add(Uint8List.fromList(<int>[1, 2, 3, 4]));

    expect(buffer.clear(), 4);
    buffer
      ..add(Uint8List.fromList(<int>[5, 6]))
      ..add(Uint8List.fromList(<int>[7, 8]));

    expect(buffer.sizeBytes, 4);
    expect(buffer.chunks.map((chunk) => chunk.toList()), <List<int>>[
      <int>[5, 6],
      <int>[7, 8],
    ]);
  });
}
