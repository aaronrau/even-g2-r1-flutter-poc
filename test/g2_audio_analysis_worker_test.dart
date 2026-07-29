import 'dart:async';
import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/audio/g2_audio_analysis_worker.dart';
import 'package:even_g2_r1_poc/src/protocol/g2_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'processes LC3 gain on a worker isolate and emits 30 Hz snapshots',
    () async {
      final quiet = Completer<G2AudioAnalysisSnapshot>();
      final speech = Completer<G2AudioAnalysisSnapshot>();
      final worker = G2AudioAnalysisWorker(
        onSnapshot: (snapshot) {
          if (snapshot.globalGain == 166 && !quiet.isCompleted) {
            quiet.complete(snapshot);
          }
          if (snapshot.globalGain == 184 && !speech.isCompleted) {
            speech.complete(snapshot);
          }
        },
      );
      addTearDown(worker.dispose);
      await worker.start();

      for (var frame = 0; frame < 100; frame++) {
        worker.addPacket(_lc3FrameWithGain(166));
      }
      final quietSnapshot = await quiet.future.timeout(
        const Duration(seconds: 2),
      );

      expect(quietSnapshot.activityLevel, 0);
      expect(quietSnapshot.noiseFloor, closeTo(166, 0.1));

      for (var frame = 0; frame < 8; frame++) {
        worker.addPacket(_lc3FrameWithGain(184));
      }
      final speechSnapshot = await speech.future.timeout(
        const Duration(seconds: 2),
      );

      expect(speechSnapshot.activityLevel, greaterThan(150));
      expect(speechSnapshot.noiseFloor, closeTo(166, 0.1));
    },
  );
}

Uint8List _lc3FrameWithGain(int gain) {
  final frame = Uint8List(40);
  frame[38] = (gain & 0x7f) << 1;
  frame[37] = gain >> 7;
  assert(G2AudioAnalysis.globalGainIndex(frame) == gain);
  return frame;
}
