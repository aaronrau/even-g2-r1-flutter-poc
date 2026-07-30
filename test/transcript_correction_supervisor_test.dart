import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/gemma_correction_client.dart';
import 'package:even_g2_r1_poc/src/audio/gemma_model.dart';
import 'package:even_g2_r1_poc/src/audio/transcript_correction_config.dart';
import 'package:even_g2_r1_poc/src/audio/transcript_correction_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory speech;
  late TranscriptCorrectionConfigStore configStore;
  late GemmaModelStore modelStore;
  late _FakeGemmaClient client;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync(
      'workbench-correction-supervisor-test-',
    );
    speech = Directory('${temp.path}/workbench/audio/speech')
      ..createSync(recursive: true);
    configStore = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    await configStore.initialize();
    modelStore = GemmaModelStore(supportDirectory: () async => temp);
    final modelDirectory = Directory(
      '${temp.path}/workbench/models/${gemma4E4bModel.id}',
    )..createSync(recursive: true);
    final model = File('${modelDirectory.path}/${gemma4E4bModel.fileName}');
    model.openSync(mode: FileMode.write)
      ..truncateSync(gemma4E4bModel.byteLength)
      ..closeSync();
    File(
      '${model.path}.verified',
    ).writeAsStringSync('${gemma4E4bModel.sha256}\n', flush: true);
    client = _FakeGemmaClient();
  });

  tearDown(() {
    configStore.dispose();
    temp.deleteSync(recursive: true);
  });

  test('prepares the verified correction engine during startup', () async {
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {},
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();

    expect(client.preparedModelPaths, hasLength(1));
    expect(client.preparedModelPaths.single, endsWith(gemma4E4bModel.fileName));
  });

  test('does not prepare the engine when correction is disabled', () async {
    await configStore.setEnabled(false);
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {},
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();

    expect(client.preparedModelPaths, isEmpty);
  });

  test(
    'persists corrected text separately with complete timing metadata',
    () async {
      final completed = Completer<CorrectedTranscriptResult>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completed.complete,
        onUncorrected: (_, _, _) {},
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/sample.raw.txt')
        ..writeAsStringSync('run test 15 with --verbose\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'sample',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'cpu',
          audioMs: 1200,
          sttDecodeMs: 80,
          sttTotalMs: 100,
          queuedAt: DateTime.now().toUtc(),
        ),
      );
      final result = await completed.future.timeout(const Duration(seconds: 5));

      expect(result.correctedText, 'Run test 15 with --verbose.');
      expect(
        File('${speech.path}/sample.corrected.txt').readAsStringSync().trim(),
        result.correctedText,
      );
      final metadata = File(
        '${speech.path}/sample.transcript.json',
      ).readAsStringSync();
      expect(metadata, contains('"runtime":"litertlm-0.14.0"'));
      expect(metadata, contains('"decodeMs":80'));
      expect(
        File('${speech.path}/pending-corrections.json').readAsStringSync(),
        '{}',
      );
    },
  );

  test(
    'uses a newly saved instruction on the next queued transcript',
    () async {
      final completions =
          StreamController<CorrectedTranscriptResult>.broadcast();
      addTearDown(completions.close);
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completions.add,
        onUncorrected: (_, _, _) {},
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      await configStore.saveInstructions('First validated instruction.');
      final firstCompletion = completions.stream.first;
      await _queue(supervisor, speech, 'first', 'first transcript');
      await firstCompletion.timeout(const Duration(seconds: 5));
      await configStore.saveInstructions('Second validated instruction.');
      final secondCompletion = completions.stream.first;
      await _queue(supervisor, speech, 'second', 'second transcript');
      await secondCompletion.timeout(const Duration(seconds: 5));

      expect(client.instructions, <String>[
        'First validated instruction.',
        'Second validated instruction.',
      ]);
    },
  );

  test('rejects correction output that removes protected values', () {
    expect(
      () => TranscriptCorrectionSupervisor.validateCorrectedTranscript(
        original: 'Run version 15 with --verbose.',
        candidate: 'Run the version.',
      ),
      throwsFormatException,
    );
    expect(
      TranscriptCorrectionSupervisor.validateCorrectedTranscript(
        original: 'run version 15 with --verbose',
        candidate: 'Run version 15 with --verbose.',
      ),
      'Run version 15 with --verbose.',
    );
  });

  test('adds conservative Hey Memo correction guidance', () {
    final instructions =
        TranscriptCorrectionSupervisor.buildCorrectionInstructions(
          'Correct only clear ASR errors.',
          const <String>['Hey Memo'],
        );

    expect(instructions, contains('exactly "Hey Memo"'));
    expect(instructions, contains('hey me mo'));
    expect(instructions, contains('I wrote a memo yesterday'));
    expect(instructions, contains('standalone "Hey"'));
    expect(instructions, contains('memo-like second word'));
    expect(instructions, contains('Never rewrite an ordinary use'));
  });

  test(
    'adds known command names and marks a live correction routable',
    () async {
      final completed = Completer<CorrectedTranscriptResult>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completed.complete,
        onUncorrected: (_, _, _) {},
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/live.raw.txt')
        ..writeAsStringSync('Hey flex, pull the latest changes.\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'live',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'nnapi',
          audioMs: 5000,
          sttDecodeMs: 500,
          sttTotalMs: 550,
          queuedAt: DateTime.now().toUtc(),
          correctionTerms: const <String>['Flux', 'Brock', 'Flux'],
          routeWhenCorrected: true,
        ),
      );
      final result = await completed.future.timeout(const Duration(seconds: 5));

      expect(result.correctedText, 'Flux, pull the latest changes.');
      expect(result.routeWhenCorrected, isTrue);
      expect(client.instructions.single, contains('["Flux","Brock"]'));
      expect(
        client.instructions.single,
        contains('"Flux":["plus","plux","flex","flax","fox"]'),
      );
      expect(
        client.instructions.single,
        contains('source begins with "Hey" followed by that alias'),
      );
      expect(
        client.instructions.single,
        contains('Never promote a bare alias such as "Plus"'),
      );
    },
  );

  test('a restored correction job can never route an old command', () {
    final original = TranscriptCorrectionJob(
      segmentId: 'pending',
      rawPath: '/private/app/pending.raw.txt',
      sttModel: 'parakeet-0.6b',
      sttProvider: 'nnapi',
      audioMs: 5000,
      sttDecodeMs: 500,
      sttTotalMs: 550,
      queuedAt: DateTime.now().toUtc(),
      correctionTerms: const <String>['Flux'],
      routeWhenCorrected: true,
    );

    final restored = TranscriptCorrectionJob.fromJson(
      original.segmentId,
      original.toJson(),
    );

    expect(restored, isNotNull);
    expect(restored!.routeWhenCorrected, isFalse);
    expect(restored.correctionTerms, isEmpty);
  });

  test(
    'disabled correction returns the live raw transcript explicitly',
    () async {
      await configStore.setEnabled(false);
      final bypassed = Completer<(TranscriptCorrectionJob, String, String)>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: (_) {},
        onUncorrected: (job, transcript, reason) {
          bypassed.complete((job, transcript, reason));
        },
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/disabled.raw.txt')
        ..writeAsStringSync('Flux, pull the latest changes.\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'disabled',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'nnapi',
          audioMs: 5000,
          sttDecodeMs: 500,
          sttTotalMs: 550,
          queuedAt: DateTime.now().toUtc(),
          routeWhenCorrected: true,
        ),
      );
      final result = await bypassed.future.timeout(const Duration(seconds: 5));

      expect(result.$1.routeWhenCorrected, isTrue);
      expect(result.$2, 'Flux, pull the latest changes.');
      expect(result.$3, 'correction_disabled');
    },
  );

  test(
    'oversize correction input is terminal without routing invalid raw text',
    () async {
      final statuses = <String>[];
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: (_) {},
        onUncorrected: (_, _, _) {
          fail('Enabled correction must not route uncorrected text.');
        },
        onStatus: (message, {isError = false}) {
          statuses.add(message);
        },
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final text =
          'a' *
          (TranscriptCorrectionSupervisor.maximumTranscriptCharacters + 1);
      final raw = File('${speech.path}/oversize.raw.txt')
        ..writeAsStringSync('$text\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'oversize',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'nnapi',
          audioMs: 5000,
          sttDecodeMs: 500,
          sttTotalMs: 550,
          queuedAt: DateTime.now().toUtc(),
          routeWhenCorrected: true,
        ),
      );
      await _waitFor(() => supervisor.pendingCount == 0);

      expect(client.instructions, isEmpty);
      expect(supervisor.pendingCount, 0);
      expect(statuses, contains(contains('state=skipped_oversize')));
      expect(
        File(
          '${speech.path}/oversize.correction-skipped.json',
        ).readAsStringSync(),
        contains('"reason":"input_too_long"'),
      );
      expect(
        File('${speech.path}/pending-corrections.json').readAsStringSync(),
        '{}',
      );
    },
  );

  test('abandons invalid model output after the retry ceiling', () async {
    final statuses = <String>[];
    final invalidClient = _InvalidGemmaClient();
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: invalidClient,
      onCorrected: (_) {
        fail('Invalid correction output must not complete.');
      },
      onUncorrected: (_, _, _) {
        fail('Enabled correction must not route uncorrected text.');
      },
      onStatus: (message, {isError = false}) {
        statuses.add(message);
      },
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    final raw = File('${speech.path}/invalid.raw.txt')
      ..writeAsStringSync('Keep protected value 15.\n');

    await supervisor.queue(
      TranscriptCorrectionJob(
        segmentId: 'invalid',
        rawPath: raw.path,
        sttModel: 'parakeet-0.6b',
        sttProvider: 'nnapi',
        audioMs: 5000,
        sttDecodeMs: 500,
        sttTotalMs: 550,
        queuedAt: DateTime.now().toUtc(),
        routeWhenCorrected: true,
        attempts: TranscriptCorrectionSupervisor.maximumCorrectionAttempts - 1,
      ),
    );
    await _waitFor(() => supervisor.pendingCount == 0);

    expect(invalidClient.calls, 1);
    expect(statuses, contains(contains('state=abandoned')));
    expect(statuses, contains(contains('error_code=invalid_output')));
    expect(
      File('${speech.path}/invalid.correction-skipped.json').readAsStringSync(),
      contains('"reason":"retry_exhausted"'),
    );
    expect(
      File('${speech.path}/pending-corrections.json').readAsStringSync(),
      '{}',
    );
  });

  test('does not restore a transcript with a durable skip marker', () async {
    File(
      '${speech.path}/terminal.raw.txt',
    ).writeAsStringSync('Keep the durable raw transcript.\n');
    File(
      '${speech.path}/terminal.correction-skipped.json',
    ).writeAsStringSync('{"version":1,"reason":"retry_exhausted"}');
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {
        fail('A terminal correction must not be restored.');
      },
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(supervisor.pendingCount, 0);
    expect(client.instructions, isEmpty);
    expect(
      File('${speech.path}/pending-corrections.json').readAsStringSync(),
      '{}',
    );
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous correction state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _queue(
  TranscriptCorrectionSupervisor supervisor,
  Directory speech,
  String id,
  String text,
) async {
  final raw = File('${speech.path}/$id.raw.txt')..writeAsStringSync('$text\n');
  await supervisor.queue(
    TranscriptCorrectionJob(
      segmentId: id,
      rawPath: raw.path,
      sttModel: 'parakeet-0.6b',
      sttProvider: 'cpu',
      audioMs: 1000,
      sttDecodeMs: 50,
      sttTotalMs: 60,
      queuedAt: DateTime.now().toUtc(),
    ),
  );
}

final class _FakeGemmaClient implements GemmaCorrectionClient {
  final List<String> instructions = <String>[];
  final List<String> preparedModelPaths = <String>[];

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {
    preparedModelPaths.add(modelPath);
  }

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    instructions.add(request.instructions);
    final source = request.transcript;
    final corrected = switch (source) {
      'run test 15 with --verbose' => 'Run test 15 with --verbose.',
      'Plus, for the latest changes.'
          when request.instructions.contains('"Flux"') =>
        'Flux, pull the latest changes.',
      'Hey flex, pull the latest changes.'
          when request.instructions.contains('"Flux"') =>
        'Flux, pull the latest changes.',
      _ => '${source[0].toUpperCase()}${source.substring(1)}.',
    };
    return GemmaCorrectionResult(
      correctedText: corrected,
      provider: 'gpu',
      engineLoadMs: 500,
      inferenceMs: 40,
      totalMs: 550,
      timeToFirstTokenMs: 20,
      prefillTokensPerSecond: 100,
      decodeTokensPerSecond: 20,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}

final class _InvalidGemmaClient implements GemmaCorrectionClient {
  int calls = 0;

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {}

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    calls++;
    return const GemmaCorrectionResult(
      correctedText: 'Protected value was removed.',
      provider: 'gpu',
      engineLoadMs: 500,
      inferenceMs: 40,
      totalMs: 550,
      timeToFirstTokenMs: 20,
      prefillTokensPerSecond: 100,
      decodeTokensPerSecond: 20,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}
