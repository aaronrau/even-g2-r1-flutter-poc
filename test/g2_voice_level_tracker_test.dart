import 'package:even_g2_r1_poc/src/audio/g2_voice_level_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('G2VoiceLevelTracker', () {
    test('keeps steady silence flat', () {
      final tracker = G2VoiceLevelTracker();

      final levels = List<int>.generate(100, (_) => tracker.addGain(166));

      expect(levels, everyElement(0));
      expect(tracker.noiseFloor, closeTo(166, 0.01));
    });

    test('rises quickly for speech above the learned floor', () {
      final tracker = G2VoiceLevelTracker();
      for (var index = 0; index < 100; index++) {
        tracker.addGain(166);
      }

      final speechLevels = List<int>.generate(8, (_) => tracker.addGain(184));

      expect(speechLevels.first, greaterThan(150));
      expect(speechLevels.last, greaterThan(245));
      expect(tracker.noiseFloor, lessThan(167));
    });

    test('falls back to flat after speech stops', () {
      final tracker = G2VoiceLevelTracker();
      for (var index = 0; index < 100; index++) {
        tracker.addGain(166);
      }
      for (var index = 0; index < 10; index++) {
        tracker.addGain(184);
      }

      final releaseLevels = List<int>.generate(40, (_) => tracker.addGain(166));

      expect(releaseLevels.first, greaterThan(0));
      expect(releaseLevels.last, 0);
    });

    test('rejects an invalid gain index', () {
      final tracker = G2VoiceLevelTracker();

      expect(() => tracker.addGain(256), throwsRangeError);
    });
  });
}
