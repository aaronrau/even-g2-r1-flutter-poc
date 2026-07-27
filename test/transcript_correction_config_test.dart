import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/transcript_correction_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-correction-config-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('creates and atomically updates validated config.json', () async {
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    addTearDown(store.dispose);

    await store.initialize();
    await store.saveInstructions('Correct only obvious ASR errors.');

    final file = File('${temp.path}/workbench/config.json');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final correction = decoded['transcriptCorrection'] as Map<String, dynamic>;
    expect(correction['instructions'], 'Correct only obvious ASR errors.');
    expect(correction['backend'], 'gpu');
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('reloads an external valid edit for the next transcript', () async {
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    addTearDown(store.dispose);
    await store.initialize();
    final file = File('${temp.path}/workbench/config.json');
    final updated = TranscriptCorrectionConfig.defaults.copyWith(
      instructions: 'Use the second validated instruction.',
    );
    await file.writeAsString(jsonEncode(updated.toJson()), flush: true);

    final loaded = await store.reloadForNextTranscript();

    expect(loaded.instructions, 'Use the second validated instruction.');
    expect(store.validationError, isNull);
  });

  test(
    'keeps the last good snapshot when an external edit is invalid',
    () async {
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
      );
      addTearDown(store.dispose);
      await store.initialize();
      await store.saveInstructions('Keep this validated instruction.');
      final file = File('${temp.path}/workbench/config.json');
      await file.writeAsString(
        '{"version":1,"transcriptCorrection":{"backend":"cpu"}}',
        flush: true,
      );

      final loaded = await store.reloadForNextTranscript();

      expect(loaded.instructions, 'Keep this validated instruction.');
      expect(store.validationError, isNotNull);
    },
  );

  test('rejects empty, oversized, and control-character instructions', () {
    expect(
      () => TranscriptCorrectionConfig.validateInstructions('  '),
      throwsFormatException,
    );
    expect(
      () => TranscriptCorrectionConfig.validateInstructions(
        'x' * (TranscriptCorrectionConfig.maximumInstructionCharacters + 1),
      ),
      throwsFormatException,
    );
    expect(
      () => TranscriptCorrectionConfig.validateInstructions('invalid\u0000'),
      throwsFormatException,
    );
  });
}
