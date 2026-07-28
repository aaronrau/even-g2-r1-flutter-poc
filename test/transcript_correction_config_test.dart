import 'dart:async';
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

  test('default instructions preserve constrained local command recovery', () {
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('Use only the known command names and acoustic aliases'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains(
        '"Plus, all the latest changes." becomes '
        '"Flux, pull the latest changes."',
      ),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('never invent a name'),
    );
    expect(
      defaultTranscriptCorrectionInstructions.length,
      lessThanOrEqualTo(
        TranscriptCorrectionConfig.maximumInstructionCharacters,
      ),
    );
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
    'loads the shared prompt at startup and before the next transcript',
    () async {
      var sharedPrompt = 'Use the shared startup instruction.';
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
        sharedInstructionsAvailable: () => true,
        sharedInstructionsReader: () async => sharedPrompt,
        sharedInstructionsWriter: (value) async => sharedPrompt = value,
      );
      addTearDown(store.dispose);

      await store.initialize();
      expect(store.config.instructions, sharedPrompt);
      var privateConfig =
          jsonDecode(
                await File('${temp.path}/workbench/config.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect(
        (privateConfig['transcriptCorrection']
            as Map<String, dynamic>)['instructions'],
        sharedPrompt,
      );

      sharedPrompt = 'Apply this external edit to the next transcription.';
      final loaded = await store.reloadForNextTranscript();

      expect(loaded.instructions, sharedPrompt);
      privateConfig =
          jsonDecode(
                await File('${temp.path}/workbench/config.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect(
        (privateConfig['transcriptCorrection']
            as Map<String, dynamic>)['instructions'],
        sharedPrompt,
      );
    },
  );

  test('creates a missing shared prompt from the private fallback', () async {
    String? sharedPrompt;
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async => sharedPrompt,
      sharedInstructionsWriter: (value) async => sharedPrompt = value,
    );
    addTearDown(store.dispose);

    await store.initialize();

    expect(sharedPrompt, defaultTranscriptCorrectionInstructions);
    expect(store.config.instructions, defaultTranscriptCorrectionInstructions);
  });

  test(
    'does not lose the last good prompt after an invalid shared edit',
    () async {
      var sharedPrompt = 'Keep this shared instruction.';
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
        sharedInstructionsAvailable: () => true,
        sharedInstructionsReader: () async => sharedPrompt,
        sharedInstructionsWriter: (value) async => sharedPrompt = value,
      );
      addTearDown(store.dispose);
      await store.initialize();

      sharedPrompt = ' \u0000 ';
      final loaded = await store.reloadForNextTranscript();

      expect(loaded.instructions, 'Keep this shared instruction.');
      expect(store.validationError, contains('Shared correction prompt'));
    },
  );

  test('a failed shared save cannot replace the private fallback', () async {
    var sharedPrompt = 'Original shared instruction.';
    var failWrites = false;
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async => sharedPrompt,
      sharedInstructionsWriter: (value) async {
        if (failWrites) {
          throw FileSystemException('Shared folder unavailable');
        }
        sharedPrompt = value;
      },
    );
    addTearDown(store.dispose);
    await store.initialize();
    failWrites = true;

    await expectLater(
      store.saveInstructions('Do not persist this failed update.'),
      throwsA(isA<FileSystemException>()),
    );

    expect(store.config.instructions, 'Original shared instruction.');
    final privateConfig =
        jsonDecode(
              await File('${temp.path}/workbench/config.json').readAsString(),
            )
            as Map<String, dynamic>;
    expect(
      (privateConfig['transcriptCorrection']
          as Map<String, dynamic>)['instructions'],
      'Original shared instruction.',
    );
  });

  test(
    'serializes a prompt reload and save so neither write is lost',
    () async {
      var sharedPrompt = 'Original shared instruction.';
      Completer<String?>? pendingRead;
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
        sharedInstructionsAvailable: () => true,
        sharedInstructionsReader: () async {
          final pending = pendingRead;
          return pending == null ? sharedPrompt : pending.future;
        },
        sharedInstructionsWriter: (value) async => sharedPrompt = value,
      );
      addTearDown(store.dispose);
      await store.initialize();

      pendingRead = Completer<String?>();
      final reload = store.reloadForNextTranscript();
      await Future<void>.delayed(Duration.zero);
      final save = store.saveInstructions('Saved after the in-flight reload.');
      await Future<void>.delayed(Duration.zero);

      expect(sharedPrompt, 'Original shared instruction.');
    pendingRead.complete(sharedPrompt);
      await reload;
      await save;

      expect(sharedPrompt, 'Saved after the in-flight reload.');
      expect(store.config.instructions, sharedPrompt);
    },
  );

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
