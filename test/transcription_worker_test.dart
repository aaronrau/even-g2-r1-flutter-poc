import 'package:even_g2_r1_poc/src/audio/transcription_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restored transcription jobs are never route eligible', () {
    final tracker = TranscriptionRecoveryTracker()
      ..restore(<String>['restored-segment']);

    expect(tracker.takeRouteEligibility('restored-segment'), isFalse);
  });

  test('live transcription jobs remain route eligible', () {
    final tracker = TranscriptionRecoveryTracker();

    expect(tracker.takeRouteEligibility('live-segment'), isTrue);
  });

  test('a new live job supersedes stale recovery state for the same id', () {
    final tracker = TranscriptionRecoveryTracker()
      ..restore(<String>['reused-segment'])
      ..markLive('reused-segment');

    expect(tracker.takeRouteEligibility('reused-segment'), isTrue);
  });
}
