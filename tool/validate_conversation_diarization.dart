import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_analysis_worker.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/speech_model.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseOptions(arguments);
  final enrollment = _requiredFile(options, 'enrollment');
  final conversation = _optionalFile(options, 'conversation');
  final turns = (options['turns'] ?? '')
      .split(',')
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .map(File.new)
      .toList(growable: false);
  final expectedTurns = (options['expected-turns'] ?? '')
      .split('|')
      .map((text) => text.trim())
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
  if (conversation == null && turns.isEmpty) {
    throw const FormatException('Provide --conversation WAV or --turns WAVS.');
  }
  if (turns.any((file) => !file.existsSync())) {
    throw StateError('One or more --turns WAV files are unavailable.');
  }
  if (expectedTurns.isNotEmpty && expectedTurns.length != turns.length) {
    throw const FormatException(
      '--expected-turns must contain one pipe-separated phrase per turn.',
    );
  }
  final root = Directory(options['repository-root'] ?? Directory.current.path);
  final clusteringThreshold =
      double.tryParse(options['cluster-threshold'] ?? '') ?? 0.01;
  final signatureMatchThreshold =
      double.tryParse(options['signature-threshold'] ?? '') ??
      defaultSpeakerSignatureMatchThreshold;
  final minimumSpeakers = int.tryParse(options['minimum-speakers'] ?? '') ?? 2;
  if (clusteringThreshold <= 0 || clusteringThreshold >= 1) {
    throw const FormatException(
      '--cluster-threshold must be greater than 0 and less than 1.',
    );
  }
  if (minimumSpeakers < 2) {
    throw const FormatException('--minimum-speakers must be at least 2.');
  }
  if (!isValidSpeakerSignatureThreshold(signatureMatchThreshold)) {
    throw const FormatException(
      '--signature-threshold must be greater than 0 and at most 1.',
    );
  }
  final models = ConversationModelPaths(
    segmentation: '${root.path}/models/diarization/segmentation.int8.onnx',
    embedding: '${root.path}/models/diarization/nemo_en_titanet_small.onnx',
  );
  final transcription = TranscriptionModelPaths(
    definition: parakeet110mModel,
    model: '${root.path}/models/stt/parakeet-110m/model.int8.onnx',
    tokens: '${root.path}/models/stt/parakeet-110m/tokens.txt',
  );
  for (final path in <String>[
    models.segmentation,
    models.embedding,
    transcription.model!,
    transcription.tokens,
  ]) {
    if (!File(path).existsSync()) {
      throw StateError('Required model file is unavailable: $path');
    }
  }

  Completer<ConversationAnalysisResult>? pending;
  final failures = <String>[];
  final status = <String>[];
  var manualRestartCount = 0;
  final supervisor = ConversationAnalysisSupervisor(
    models: models,
    transcription: transcription,
    onResult: (result) => pending?.complete(result),
    onFailure: (segmentId, error) {
      failures.add(segmentId);
      pending?.completeError(error);
    },
    onStatus: (message, {bool isError = false}) {
      if (message.contains('state=restarting reason=manual_test')) {
        manualRestartCount++;
      }
      final state = RegExp(r'state=([a-z_]+)').firstMatch(message)?.group(1);
      if (state != null) {
        status.add(state);
      }
    },
    clusteringThreshold: clusteringThreshold,
    signatureMatchThreshold: signatureMatchThreshold,
  );
  try {
    await supervisor.start();
    var profiles = const <SpeakerProfile>[];

    pending = Completer<ConversationAnalysisResult>();
    supervisor.analyze(
      segmentId: 'offline-enrollment',
      wavPath: enrollment.path,
      profiles: profiles,
      enrollment: true,
    );
    final enrolled = await pending.future.timeout(const Duration(minutes: 2));
    profiles = enrolled.profiles;
    if (profiles.length != 1 || !profiles.single.isPrimary) {
      throw StateError('Offline enrollment did not create one primary user.');
    }

    pending = null;
    await supervisor.restartForTest();
    await _waitUntil(
      () => !supervisor.isReady,
      timeout: const Duration(seconds: 5),
    );
    await _waitUntil(
      () => supervisor.isReady,
      timeout: const Duration(minutes: 1),
    );

    final firstLabels = <String>[];
    final secondLabels = <String>[];
    final firstConfidences = <double>[];
    final secondConfidences = <double>[];
    final wordErrorRates = <double>[];
    var firstConversationTurns = 0;
    var secondConversationTurns = 0;
    if (turns.isNotEmpty) {
      for (var index = 0; index < turns.length; index++) {
        pending = Completer<ConversationAnalysisResult>();
        supervisor.analyze(
          segmentId: 'offline-turn-first-${index + 1}',
          wavPath: turns[index].path,
          profiles: profiles,
          enrollment: false,
        );
        if (index == 0) {
          await supervisor.restartForTest();
        }
        final result = await pending.future.timeout(const Duration(minutes: 2));
        profiles = result.profiles;
        if (result.record.utterances.length != 1) {
          throw StateError(
            'An isolated turn did not produce one speaker-attributed turn.',
          );
        }
        final utterance = result.record.utterances.single;
        firstLabels.add(utterance.speakerLabel);
        firstConfidences.add(utterance.confidence);
        firstConversationTurns += result.record.utterances.length;
        if (expectedTurns.isNotEmpty) {
          wordErrorRates.add(
            _wordErrorRate(expectedTurns[index], utterance.text),
          );
        }
      }
      final firstProfileCount = profiles.length;
      if (!firstLabels.contains('You') ||
          firstLabels.toSet().length < minimumSpeakers ||
          firstProfileCount < minimumSpeakers) {
        throw StateError(
          'The isolated turns did not alternate between saved speakers.',
        );
      }
      for (var index = 0; index < turns.length; index++) {
        pending = Completer<ConversationAnalysisResult>();
        supervisor.analyze(
          segmentId: 'offline-turn-second-${index + 1}',
          wavPath: turns[index].path,
          profiles: profiles,
          enrollment: false,
        );
        final result = await pending.future.timeout(const Duration(minutes: 2));
        profiles = result.profiles;
        if (result.record.utterances.length != 1) {
          throw StateError('A repeated isolated turn lost its attribution.');
        }
        final utterance = result.record.utterances.single;
        secondLabels.add(utterance.speakerLabel);
        secondConfidences.add(utterance.confidence);
        secondConversationTurns += result.record.utterances.length;
      }
      if (profiles.length != firstProfileCount ||
          !_sameValues(firstLabels, secondLabels)) {
        throw StateError(
          'A repeated sample changed saved speaker attribution.',
        );
      }
      if (wordErrorRates.any((value) => value > 0.35)) {
        throw StateError(
          'One or more clean Kokoro turns exceeded the STT WER threshold.',
        );
      }
    } else {
      pending = Completer<ConversationAnalysisResult>();
      supervisor.analyze(
        segmentId: 'offline-conversation-1',
        wavPath: conversation!.path,
        profiles: profiles,
        enrollment: false,
      );
      final first = await pending.future.timeout(const Duration(minutes: 2));
      profiles = first.profiles;
      final firstProfileCount = profiles.length;
      firstConversationTurns = first.record.utterances.length;
      firstLabels.addAll(
        first.record.utterances.map((utterance) => utterance.speakerLabel),
      );
      firstConfidences.addAll(
        first.record.utterances.map((utterance) => utterance.confidence),
      );
      if (firstConversationTurns < 2 || firstLabels.toSet().length < 2) {
        throw StateError(
          'The alternating sample did not produce multiple speaker turns.',
        );
      }

      pending = Completer<ConversationAnalysisResult>();
      supervisor.analyze(
        segmentId: 'offline-conversation-2',
        wavPath: conversation.path,
        profiles: profiles,
        enrollment: false,
      );
      final second = await pending.future.timeout(const Duration(minutes: 2));
      profiles = second.profiles;
      secondConversationTurns = second.record.utterances.length;
      secondLabels.addAll(
        second.record.utterances.map((utterance) => utterance.speakerLabel),
      );
      secondConfidences.addAll(
        second.record.utterances.map((utterance) => utterance.confidence),
      );
      if (profiles.length != firstProfileCount) {
        throw StateError(
          'A repeated sample created duplicate saved speaker profiles.',
        );
      }
      if (secondConversationTurns < 2) {
        throw StateError('The repeated sample lost speaker turns.');
      }
    }

    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(<String, Object>{
        'passed': true,
        'enrollmentProfiles': enrolled.profiles.length,
        'firstConversationTurns': firstConversationTurns,
        'secondConversationTurns': secondConversationTurns,
        'stableAttribution': _sameValues(firstLabels, secondLabels),
        'firstMatchConfidences': firstConfidences,
        'secondMatchConfidences': secondConfidences,
        'savedProfiles': profiles.length,
        'profileSimilarities': _profileSimilarities(profiles),
        'maximumWordErrorRate': wordErrorRates.isEmpty
            ? 0
            : wordErrorRates.reduce(
                (left, right) => left > right ? left : right,
              ),
        'clusterThreshold': clusteringThreshold,
        'signatureMatchThreshold': signatureMatchThreshold,
        'minimumSpeakers': minimumSpeakers,
        'workerRestartObserved': status.contains('restarting'),
        'inFlightWorkerRestartObserved': turns.isNotEmpty
            ? manualRestartCount >= 2
            : false,
        'failures': failures.length,
      }),
    );
  } finally {
    await supervisor.dispose();
  }
}

List<Map<String, Object>> _profileSimilarities(List<SpeakerProfile> profiles) {
  final similarities = <Map<String, Object>>[];
  for (var left = 0; left < profiles.length; left++) {
    for (var right = left + 1; right < profiles.length; right++) {
      similarities.add(<String, Object>{
        'left': profiles[left].label,
        'right': profiles[right].label,
        'similarity': speakerSimilarity(
          profiles[left].embedding,
          profiles[right].embedding,
        ),
      });
    }
  }
  return similarities;
}

Map<String, String> _parseOptions(List<String> arguments) {
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    final key = arguments[index];
    if (!key.startsWith('--') || index + 1 >= arguments.length) {
      throw const FormatException(
        'Use --enrollment WAV --conversation WAV '
        'or --enrollment WAV --turns WAV,WAV '
        '[--expected-turns "TEXT|TEXT"] [--repository-root DIRECTORY] '
        '[--cluster-threshold NUMBER] [--signature-threshold NUMBER] '
        '[--minimum-speakers NUMBER].',
      );
    }
    values[key.substring(2)] = arguments[index + 1];
  }
  return values;
}

File _requiredFile(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) {
    throw FormatException('Missing --$name WAV.');
  }
  final file = File(value);
  if (!file.existsSync()) {
    throw StateError('Input WAV is unavailable: ${file.path}');
  }
  return file;
}

File? _optionalFile(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  final file = File(value);
  if (!file.existsSync()) {
    throw StateError('Input WAV is unavailable: ${file.path}');
  }
  return file;
}

bool _sameValues(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

double _wordErrorRate(String expected, String actual) {
  final reference = _words(expected);
  final hypothesis = _words(actual);
  if (reference.isEmpty) {
    return hypothesis.isEmpty ? 0 : 1;
  }
  var previous = List<int>.generate(hypothesis.length + 1, (index) => index);
  for (var row = 1; row <= reference.length; row++) {
    final current = List<int>.filled(hypothesis.length + 1, 0);
    current[0] = row;
    for (var column = 1; column <= hypothesis.length; column++) {
      final substitution =
          previous[column - 1] +
          (reference[row - 1] == hypothesis[column - 1] ? 0 : 1);
      final deletion = previous[column] + 1;
      final insertion = current[column - 1] + 1;
      current[column] = [
        substitution,
        deletion,
        insertion,
      ].reduce((left, right) => left < right ? left : right);
    }
    previous = current;
  }
  return previous.last / reference.length;
}

List<String> _words(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .toList(growable: false);

Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  final timer = Stopwatch()..start();
  while (!predicate()) {
    if (timer.elapsed > timeout) {
      throw TimeoutException('Timed out waiting for worker recovery.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
