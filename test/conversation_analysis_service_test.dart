import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_analysis_service.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_record_store.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'compacts legacy profiles and resets You before the next new segment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final temporary = await Directory.systemTemp.createTemp(
        'workbench-conversation-reset.',
      );
      final store = ConversationRecordStore(
        supportDirectory: () async => temporary,
      );
      await store.initialize();
      final now = DateTime.utc(2026, 7, 28, 12);
      await store.saveProfiles(<SpeakerProfile>[
        for (var index = 0; index < 20; index++)
          SpeakerProfile(
            id: 'speaker-$index',
            label: 'Speaker ${index + 2}',
            embedding: const <double>[0, 1],
            sampleCount: 1,
            createdAt: now,
            updatedAt: now.add(Duration(minutes: index)),
          ),
        SpeakerProfile(
          id: 'primary-user',
          label: 'You',
          embedding: const <double>[1, 0],
          sampleCount: 1,
          createdAt: now,
          updatedAt: now,
          isPrimary: true,
        ),
      ]);
      final logs = <String>[];
      final service = ConversationAnalysisService(
        log: (_, message, {bool isError = false}) => logs.add(message),
        onChanged: () {},
        sharedAudioExportStore: SharedAudioExportStore(isAndroid: false),
        recordStore: store,
        clock: () => now,
      );
      addTearDown(() async {
        await service.dispose();
        await temporary.delete(recursive: true);
      });

      await service.initialize();

      expect(service.knownSpeakerCount, maximumNonPrimarySpeakerProfiles + 1);
      expect(logs, contains(contains('state=profiles_compacted')));

      // Enabling directly keeps this unit test independent from native model
      // startup while exercising the same reset and handoff state machine.
      service.enabled = true;
      await service.resetPrimarySpeakerProfile();

      expect(service.needsEnrollment, isTrue);
      expect(service.isEnrollmentPending, isTrue);
      expect(service.knownSpeakerCount, maximumNonPrimarySpeakerProfiles);
      final savedAfterReset = await store.loadProfiles();
      expect(savedAfterReset.any((profile) => profile.isPrimary), isFalse);

      final resetMicros = now.microsecondsSinceEpoch;
      service.acceptFinalizedSegment(
        '${resetMicros - 1}-old',
        '${temporary.path}/old.wav',
      );
      expect(service.pendingCount, 0);
      expect(service.state, 'waiting_for_enrollment_speech');
      expect(logs, contains(contains('reason=started_before_reset')));

      service.acceptFinalizedSegment(
        '${resetMicros + 1}-new',
        '${temporary.path}/new.wav',
      );
      expect(service.pendingCount, 1);
      expect(service.isEnrollmentPending, isTrue);
      expect(service.state, 'enrolling');

      service.acceptFinalizedSegment(
        '${resetMicros + 2}-too-soon',
        '${temporary.path}/too-soon.wav',
      );
      expect(service.pendingCount, 1);
      expect(logs, contains(contains('sample_analysis_in_progress')));
    },
  );
}
