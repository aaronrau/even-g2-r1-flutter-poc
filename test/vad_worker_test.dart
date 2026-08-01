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

  test('prefers a pause after 15 seconds and hard-caps at 17 seconds', () {
    expect(preferredVadSegmentDuration, const Duration(seconds: 15));
    expect(maximumVadSegmentDuration, const Duration(seconds: 17));
    expect(vadRolloverOverlapDuration, const Duration(seconds: 1));
    expect(vadWordBoundaryQuietDuration, const Duration(milliseconds: 75));
    final tracker = VadSegmentDurationTracker(sampleRate: 16000);

    for (var second = 0; second < 14; second++) {
      expect(tracker.add(16000), isFalse);
    }
    expect(tracker.samples, 14 * 16000);
    expect(tracker.add(16000), isFalse);
    expect(tracker.shouldPreferVadPause, isTrue);
    expect(
      tracker.shouldSplitAtVadResume(detected: true, endpointActive: true),
      isTrue,
    );
    expect(
      tracker.shouldSplitAtVadResume(detected: true, endpointActive: false),
      isFalse,
    );
    expect(tracker.add(16000), isFalse);
    expect(tracker.add(16000), isTrue);
    expect(tracker.reachedHardLimit, isTrue);

    tracker.reset();
    expect(tracker.samples, 0);
    expect(tracker.shouldPreferVadPause, isFalse);
    expect(tracker.add(160), isFalse);
  });

  test('selects the first credible inter-word quiet gap after soft target', () {
    final detector = VadWordBoundaryDetector(sampleRate: 1000);

    expect(
      detector.observe(
        _pcm(samples: 100, amplitude: 2000),
        seekBoundary: false,
      ),
      isFalse,
    );
    expect(
      detector.observe(_pcm(samples: 40, amplitude: 100), seekBoundary: true),
      isFalse,
    );
    expect(
      detector.observe(_pcm(samples: 40, amplitude: 100), seekBoundary: true),
      isFalse,
    );
    expect(
      detector.observe(_pcm(samples: 50, amplitude: 2000), seekBoundary: true),
      isTrue,
    );
  });

  test('does not treat a short low-energy phoneme as a word boundary', () {
    final detector = VadWordBoundaryDetector(sampleRate: 1000);

    detector.observe(_pcm(samples: 100, amplitude: 2000), seekBoundary: false);
    detector.observe(_pcm(samples: 50, amplitude: 100), seekBoundary: true);

    expect(
      detector.observe(_pcm(samples: 50, amplitude: 2000), seekBoundary: true),
      isFalse,
    );
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

Uint8List _pcm({required int samples, required int amplitude}) {
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples; index++) {
    data.setInt16(index * 2, amplitude, Endian.little);
  }
  return bytes;
}
