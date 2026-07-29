import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_analysis_preferences.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'conversation analysis is disabled by default and persists opt-in',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const preferences = ConversationAnalysisPreferences();

      expect(await preferences.loadEnabled(), isFalse);
      await preferences.saveEnabled(true);
      expect(await preferences.loadEnabled(), isTrue);
    },
  );

  test('speaker signatures normalize, match, and update as centroids', () {
    final now = DateTime.utc(2026, 1, 1);
    final profile = SpeakerProfile(
      id: 'primary-user',
      label: 'You',
      embedding: const <double>[1, 0],
      sampleCount: 1,
      createdAt: now,
      updatedAt: now,
      isPrimary: true,
    );
    final updated = profile.merge(const <double>[
      0.8,
      0.2,
    ], now.add(const Duration(seconds: 1)));

    expect(updated.sampleCount, 2);
    expect(updated.isPrimary, isTrue);
    expect(updated.signatures, hasLength(2));
    expect(
      speakerProfileSimilarity(updated, const <double>[1, 0]),
      closeTo(1, 0.0001),
    );
    expect(
      speakerSimilarity(profile.embedding, updated.embedding),
      closeTo(0.99, 0.02),
    );
    expect(speakerSimilarity(const <double>[1, 0], const <double>[0, 1]), 0);
    expect(
      SpeakerProfile.fromJson(updated.toJson()).embedding,
      updated.embedding,
    );
    final legacyJson = Map<String, Object>.from(updated.toJson())
      ..remove('signatures');
    expect(SpeakerProfile.fromJson(legacyJson).signatures, isEmpty);
  });

  test('signature threshold accepts same-speaker acoustic variation', () {
    final now = DateTime.utc(2026, 1, 1);
    final profile = SpeakerProfile(
      id: 'primary-user',
      label: 'You',
      embedding: const <double>[1, 0],
      sampleCount: 1,
      createdAt: now,
      updatedAt: now,
      isPrimary: true,
    );
    final similarity = speakerProfileSimilarity(profile, const <double>[
      0.645,
      0.764182,
    ]);

    expect(similarity, closeTo(0.645, 0.0001));
    expect(similarity, lessThan(0.65));
    expect(speakerSignatureMatches(similarity), isTrue);
    expect(speakerSignatureMatches(0.6390224), isFalse);
    expect(
      speakerSignatureMatches(defaultSpeakerSignatureMatchThreshold),
      isTrue,
    );
    expect(
      () => speakerSignatureMatches(0.9, threshold: 0),
      throwsArgumentError,
    );
  });

  test('resetting You retains every non-primary speaker profile', () {
    final now = DateTime.utc(2026, 1, 1);
    final primary = SpeakerProfile(
      id: 'primary-user',
      label: 'You',
      embedding: const <double>[1, 0],
      sampleCount: 1,
      createdAt: now,
      updatedAt: now,
      isPrimary: true,
    );
    final other = SpeakerProfile(
      id: 'speaker-2',
      label: 'Speaker 2',
      embedding: const <double>[0, 1],
      sampleCount: 1,
      createdAt: now,
      updatedAt: now,
    );

    final retained = retainNonPrimarySpeakerProfiles(<SpeakerProfile>[
      primary,
      other,
    ]);

    expect(retained, <SpeakerProfile>[other]);
    expect(retained.any((profile) => profile.isPrimary), isFalse);
  });

  test('speaker profile bank keeps one primary and recent other speakers', () {
    final now = DateTime.utc(2026, 1, 1);
    final profiles = <SpeakerProfile>[
      SpeakerProfile(
        id: 'primary-old',
        label: 'You',
        embedding: const <double>[1, 0],
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
        isPrimary: true,
      ),
      SpeakerProfile(
        id: 'primary-current',
        label: 'You',
        embedding: const <double>[1, 0],
        sampleCount: 2,
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 1)),
        isPrimary: true,
      ),
      for (var index = 0; index < 20; index++)
        SpeakerProfile(
          id: 'speaker-$index',
          label: 'Speaker ${index + 2}',
          embedding: const <double>[0, 1],
          sampleCount: 1,
          createdAt: now,
          updatedAt: now.add(Duration(minutes: index)),
        ),
    ];

    final retained = retainBoundedSpeakerProfiles(profiles);

    expect(retained, hasLength(maximumNonPrimarySpeakerProfiles + 1));
    expect(
      retained.where((profile) => profile.isPrimary).single.id,
      'primary-current',
    );
    expect(retained.any((profile) => profile.id == 'speaker-0'), isFalse);
    expect(retained.any((profile) => profile.id == 'speaker-19'), isTrue);
    expect(nextNonPrimarySpeakerLabel(retained), 'Speaker 22');
  });

  test('conversation records preserve speaker labels and overlap metadata', () {
    final now = DateTime.utc(2026, 1, 1);
    final record = ConversationRecord(
      id: 'synthetic-segment',
      audioPath: '/private/synthetic-segment.wav',
      textPath: '/private/synthetic-segment.conversation.txt',
      metadataPath: '/private/synthetic-segment.conversation.json',
      updatedAt: now,
      utterances: <ConversationUtterance>[
        ConversationUtterance(
          id: 'synthetic-segment-1',
          conversationId: 'synthetic-segment',
          speakerId: 'primary-user',
          speakerLabel: 'You',
          text: 'Synthetic test phrase.',
          startMs: 0,
          endMs: 1000,
          confidence: 0.9,
          updatedAt: now,
          isPrimary: true,
        ),
        ConversationUtterance(
          id: 'synthetic-segment-2',
          conversationId: 'synthetic-segment',
          speakerId: 'overlap',
          speakerLabel: 'Overlapping speakers',
          text: 'Synthetic overlapping phrase.',
          startMs: 800,
          endMs: 1800,
          confidence: 0.5,
          updatedAt: now,
          isOverlap: true,
        ),
      ],
    );

    final restored = ConversationRecord.fromJson(record.toJson());

    expect(restored.utterances, hasLength(2));
    expect(restored.utterances.first.isPrimary, isTrue);
    expect(restored.utterances.last.isOverlap, isTrue);
    expect(restored.encode(), contains('"speakerLabel": "You"'));
  });

  test(
    'record store atomically restores profiles, jobs, and conversations',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'workbench-conversation-store.',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final store = ConversationRecordStore(
        supportDirectory: () async => temporary,
      );
      await store.initialize();
      final now = DateTime.utc(2026, 1, 1);
      final wav = File('${temporary.path}/synthetic.wav');
      await wav.writeAsBytes(<int>[1, 2, 3], flush: true);
      final profile = SpeakerProfile(
        id: 'primary-user',
        label: 'You',
        embedding: const <double>[1, 0],
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
        isPrimary: true,
      );
      final otherProfile = SpeakerProfile(
        id: 'speaker-2',
        label: 'Speaker 2',
        embedding: const <double>[0, 1],
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
      );
      final job = ConversationPendingJob(
        segmentId: 'synthetic',
        wavPath: wav.path,
        enrollment: true,
        queuedAt: now,
      );
      final record = ConversationRecord(
        id: 'synthetic',
        audioPath: wav.path,
        textPath: '${temporary.path}/synthetic.conversation.txt',
        metadataPath: '${temporary.path}/source.json',
        utterances: <ConversationUtterance>[
          ConversationUtterance(
            id: 'synthetic-1',
            conversationId: 'synthetic',
            speakerId: 'primary-user',
            speakerLabel: 'You',
            text: 'Synthetic retained text.',
            startMs: 0,
            endMs: 1000,
            confidence: 1,
            updatedAt: now,
            isPrimary: true,
          ),
        ],
        updatedAt: now,
      );

      await store.saveProfiles(<SpeakerProfile>[profile, otherProfile]);
      await store.savePendingJobs(<ConversationPendingJob>[job]);
      final retained = await store.retainRecord(record);

      expect(await store.loadProfiles(), hasLength(2));
      expect(await store.loadPendingJobs(), hasLength(1));
      expect(await store.loadRecords(), hasLength(1));
      expect(retained.metadataPath, endsWith('synthetic.conversation.json'));
      expect(File('${retained.metadataPath}.part').existsSync(), isFalse);

      await store.saveProfiles(
        retainNonPrimarySpeakerProfiles(await store.loadProfiles()),
      );
      final profilesAfterPrimaryReset = await store.loadProfiles();
      expect(profilesAfterPrimaryReset, hasLength(1));
      expect(profilesAfterPrimaryReset.single.id, 'speaker-2');
      expect(profilesAfterPrimaryReset.single.isPrimary, isFalse);
    },
  );
}
