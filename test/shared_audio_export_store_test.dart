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
      expect(call.method, 'currentDirectory');
      return <String, Object>{'displayName': 'Work Bench Audio'};
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);

    await store.initialize();

    expect(store.folder?.displayName, 'Work Bench Audio');
    expect(store.hasSharedFolder, isTrue);
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
    await store.initialize();

    await store.clearFolder();

    expect(store.folder, isNull);
    expect(store.hasSharedFolder, isFalse);
  });
}
