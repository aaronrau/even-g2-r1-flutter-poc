import 'package:even_g2_r1_poc/src/audio/transcription_chunking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps short audio in one unchanged inference window', () {
    final windows = planTranscriptionWindows(
      totalSamples: 15 * 16000,
      sampleRate: 16000,
    );

    expect(windows, hasLength(1));
    expect(windows.single.start, 0);
    expect(windows.single.end, 15 * 16000);
  });

  test('bounds long inference windows while retaining the final tail', () {
    final windows = planTranscriptionWindows(
      totalSamples: 100 * 16000,
      sampleRate: 16000,
    );

    expect(windows.length, greaterThan(1));
    expect(windows.every((window) => window.length <= 18 * 16000), isTrue);
    expect(windows.first.start, 0);
    expect(windows.last.end, 100 * 16000);
    for (var index = 1; index < windows.length; index++) {
      expect(
        windows[index - 1].end - windows[index].start,
        500 * 16000 ~/ 1000,
      );
    }
  });

  test('deduplicates exact words produced by overlapping windows', () {
    expect(
      mergeTranscriptionWindows(<String>[
        'Please inspect the audio pipeline and run',
        'pipeline and run every stability test.',
      ]),
      'Please inspect the audio pipeline and run every stability test.',
    );
  });

  test('preserves unmatched words from every inference window', () {
    expect(
      mergeTranscriptionWindows(<String>[
        'First complete clause.',
        'Second complete clause.',
      ]),
      'First complete clause. Second complete clause.',
    );
  });
}
