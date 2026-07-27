import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/workbench_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('restores a persisted shared folder without exposing its URI', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{
          'displayName': 'Work Bench Audio',
        },
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);

    await store.initialize();

    expect(store.folder?.displayName, 'Work Bench Audio');
    expect(store.hasSharedFolder, isTrue);
    expect(store.transcripts, isEmpty);
  });

  test('keeps the current folder when the picker is cancelled', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Current'},
        'chooseDirectory' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    expect(await store.chooseFolder(), isNull);
    expect(store.folder?.displayName, 'Current');
  });

  test('exports only final WAV and text files once', () async {
    List<String>? exportedPaths;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'exportFiles' => () {
          exportedPaths =
              ((call.arguments as Map<Object?, Object?>)['paths']!
                      as List<Object?>)
                  .cast<String>();
          return exportedPaths!.length;
        }(),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    final count = await store.exportFiles(<String>[
      '/private/segment.wav',
      '/private/segment.wav',
      '/private/segment.txt',
      '/private/segment.part.wav',
      '/private/transcripts.jsonl',
    ]);

    expect(count, 2);
    expect(exportedPaths, <String>[
      '/private/segment.wav',
      '/private/segment.txt',
    ]);
  });

  test('clears shared folder access', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'clearDirectory' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    await store.clearFolder();

    expect(store.folder, isNull);
    expect(store.hasSharedFolder, isFalse);
  });

  test('loads saved transcripts and controls shared WAV playback', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'listTranscriptions' => <Object?>[
          <Object?, Object?>{
            'id': 'older',
            'originalText': 'Older raw transcript',
            'correctedText': 'Older transcript',
            'audioFileName': 'older.wav',
            'updatedAtMillis': 1000,
          },
          <Object?, Object?>{
            'id': 'newer',
            'originalText': 'Newer raw transcript',
            'correctedText': 'Newer transcript',
            'audioFileName': 'newer.wav',
            'updatedAtMillis': 2000,
          },
          <Object?, Object?>{
            'id': 'invalid',
            'originalText': '',
            'updatedAtMillis': 3000,
          },
        ],
        'playAudio' => null,
        'stopAudio' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);

    await store.initialize();
    expect(store.transcripts, isEmpty);
    await store.refreshTranscriptions();

    expect(store.transcripts.map((transcript) => transcript.text), <String>[
      'Newer transcript',
      'Older transcript',
    ]);
    final newest = store.transcripts.first;
    await store.toggleAudio(newest);
    expect(store.playingAudioFileName, 'newer.wav');

    await store.toggleAudio(newest);
    expect(store.playingAudioFileName, isNull);
    expect(calls, containsAllInOrder(<String>['playAudio', 'stopAudio']));
  });

  test(
    'reports shared-folder read failures without dropping the grant',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'currentDirectory' => <String, Object>{'displayName': 'Shared'},
          'listTranscriptions' => throw PlatformException(code: 'list_failed'),
          _ => fail('Unexpected method ${call.method}'),
        };
      });
      final store = SharedAudioExportStore(channel: channel, isAndroid: true);
      addTearDown(store.dispose);

      await store.initialize();
      await expectLater(
        store.refreshTranscriptions(),
        throwsA(isA<PlatformException>()),
      );

      expect(store.folder?.displayName, 'Shared');
      expect(store.transcriptLoadError, contains('Could not read'));
      expect(store.isLoadingTranscripts, isFalse);
    },
  );

  test('clears optimistic playback state when native playback fails', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'playAudio' => throw PlatformException(code: 'audio_playback'),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    final transcript = SharedTranscript(
      id: 'sample',
      originalText: 'Generic sample transcript',
      audioFileName: 'sample.wav',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await expectLater(
      store.toggleAudio(transcript),
      throwsA(isA<PlatformException>()),
    );

    expect(store.playingAudioFileName, isNull);
  });
}
