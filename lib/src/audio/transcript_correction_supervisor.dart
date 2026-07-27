import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'gemma_correction_client.dart';
import 'gemma_model.dart';
import 'transcript_correction_config.dart';

typedef CorrectionStatusSink = void Function(String message, {bool isError});
typedef CorrectedTranscriptSink =
    void Function(CorrectedTranscriptResult result);

final class TranscriptCorrectionJob {
  const TranscriptCorrectionJob({
    required this.segmentId,
    required this.rawPath,
    required this.sttModel,
    required this.sttProvider,
    required this.audioMs,
    required this.sttDecodeMs,
    required this.sttTotalMs,
    required this.queuedAt,
    this.attempts = 0,
    this.nextAttemptAt,
  });

  final String segmentId;
  final String rawPath;
  final String sttModel;
  final String sttProvider;
  final int audioMs;
  final int sttDecodeMs;
  final int sttTotalMs;
  final DateTime queuedAt;
  final int attempts;
  final DateTime? nextAttemptAt;

  TranscriptCorrectionJob retryAfter(Duration delay) => TranscriptCorrectionJob(
    segmentId: segmentId,
    rawPath: rawPath,
    sttModel: sttModel,
    sttProvider: sttProvider,
    audioMs: audioMs,
    sttDecodeMs: sttDecodeMs,
    sttTotalMs: sttTotalMs,
    queuedAt: queuedAt,
    attempts: attempts + 1,
    nextAttemptAt: DateTime.now().toUtc().add(delay),
  );

  Map<String, Object> toJson() => <String, Object>{
    'rawPath': rawPath,
    'sttModel': sttModel,
    'sttProvider': sttProvider,
    'audioMs': audioMs,
    'sttDecodeMs': sttDecodeMs,
    'sttTotalMs': sttTotalMs,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
    'attempts': attempts,
    if (nextAttemptAt != null)
      'nextAttemptAt': nextAttemptAt!.toUtc().toIso8601String(),
  };

  static TranscriptCorrectionJob? fromJson(String id, Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final rawPath = value['rawPath'];
    final queuedAt = DateTime.tryParse('${value['queuedAt']}');
    if (rawPath is! String || rawPath.isEmpty || queuedAt == null) {
      return null;
    }
    return TranscriptCorrectionJob(
      segmentId: id,
      rawPath: rawPath,
      sttModel: '${value['sttModel'] ?? 'unknown'}',
      sttProvider: '${value['sttProvider'] ?? 'unknown'}',
      audioMs: (value['audioMs'] as num?)?.toInt() ?? 0,
      sttDecodeMs: (value['sttDecodeMs'] as num?)?.toInt() ?? 0,
      sttTotalMs: (value['sttTotalMs'] as num?)?.toInt() ?? 0,
      queuedAt: queuedAt.toUtc(),
      attempts: (value['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: DateTime.tryParse(
        '${value['nextAttemptAt'] ?? ''}',
      )?.toUtc(),
    );
  }
}

final class CorrectedTranscriptResult {
  const CorrectedTranscriptResult({
    required this.segmentId,
    required this.originalText,
    required this.correctedText,
    required this.correctedPath,
    required this.provider,
    required this.queueMs,
    required this.engineLoadMs,
    required this.inferenceMs,
    required this.correctionTotalMs,
    required this.pipelineTotalMs,
  });

  final String segmentId;
  final String originalText;
  final String correctedText;
  final String correctedPath;
  final String provider;
  final int queueMs;
  final int engineLoadMs;
  final int inferenceMs;
  final int correctionTotalMs;
  final int pipelineTotalMs;
}

final class TranscriptCorrectionSupervisor {
  TranscriptCorrectionSupervisor({
    required this.speechPath,
    required this.configStore,
    required this.modelStore,
    required this.onCorrected,
    required this.onStatus,
    GemmaCorrectionClient? client,
  }) : _client = client ?? PlatformGemmaCorrectionClient();

  final String speechPath;
  final TranscriptCorrectionConfigStore configStore;
  final GemmaModelStore modelStore;
  final CorrectedTranscriptSink onCorrected;
  final CorrectionStatusSink onStatus;
  final GemmaCorrectionClient _client;
  final LinkedHashMap<String, TranscriptCorrectionJob> _pending =
      LinkedHashMap<String, TranscriptCorrectionJob>();

  Timer? _pumpTimer;
  bool _pumping = false;
  bool _disposed = false;
  String? activeProvider;
  String state = 'idle';

  int get pendingCount => _pending.length;

  Future<void> start() async {
    await _restorePending();
    final installed = await modelStore.installedModelPath() != null;
    state = installed ? 'ready' : 'model missing';
    onStatus(
      '[WorkBench][Correction] state=${installed ? 'ready' : 'model_missing'} '
      'model=${gemma4E4bModel.id} provider=gpu '
      'pending=${_pending.length}',
      isError: !installed,
    );
    _schedulePump(Duration.zero);
  }

  Future<void> queue(TranscriptCorrectionJob job) async {
    if (_disposed) {
      return;
    }
    _pending[job.segmentId] = job;
    await _persistPending();
    onStatus(
      '[WorkBench][Correction] state=queued segment=${job.segmentId} '
      'pending=${_pending.length} stt_decode_ms=${job.sttDecodeMs} '
      'stt_total_ms=${job.sttTotalMs}',
    );
    _schedulePump(Duration.zero);
  }

  void _schedulePump(Duration delay) {
    if (_disposed) {
      return;
    }
    _pumpTimer?.cancel();
    _pumpTimer = Timer(delay, () {
      _pumpTimer = null;
      unawaited(_pump());
    });
  }

  Future<void> _pump() async {
    if (_disposed || _pumping || _pending.isEmpty) {
      return;
    }
    _pumping = true;
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final now = DateTime.now().toUtc();
        final ready = _pending.values
            .where(
              (job) =>
                  job.nextAttemptAt == null || !job.nextAttemptAt!.isAfter(now),
            )
            .firstOrNull;
        if (ready == null) {
          final earliest = _pending.values
              .map((job) => job.nextAttemptAt)
              .whereType<DateTime>()
              .reduce((left, right) => left.isBefore(right) ? left : right);
          _schedulePump(earliest.difference(now));
          break;
        }
        await _process(ready);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _process(TranscriptCorrectionJob job) async {
    final rawFile = File(job.rawPath);
    if (!await rawFile.exists()) {
      _pending.remove(job.segmentId);
      await _persistPending();
      onStatus(
        '[WorkBench][Correction] state=dropped_missing_raw '
        'segment=${job.segmentId}',
        isError: true,
      );
      return;
    }
    final rawText = (await rawFile.readAsString()).trim();
    if (rawText.isEmpty) {
      _pending.remove(job.segmentId);
      await _persistPending();
      onStatus(
        '[WorkBench][Correction] state=skipped_empty segment=${job.segmentId}',
      );
      return;
    }

    final config = await configStore.reloadForNextTranscript();
    if (!config.enabled) {
      _pending.remove(job.segmentId);
      await _persistPending();
      onStatus(
        '[WorkBench][Correction] state=disabled segment=${job.segmentId}',
      );
      return;
    }
    final modelPath = await modelStore.installedModelPath();
    if (modelPath == null) {
      await _retry(
        job,
        StateError(
          '${gemma4E4bModel.displayName} is not installed or verified.',
        ),
        minimumDelay: const Duration(minutes: 1),
      );
      return;
    }

    final queueMs = DateTime.now()
        .toUtc()
        .difference(job.queuedAt)
        .inMilliseconds;
    state = 'processing';
    onStatus(
      '[WorkBench][Correction] state=processing segment=${job.segmentId} '
      'model=${config.modelId} provider=gpu queue_ms=$queueMs '
      'attempt=${job.attempts + 1}',
    );
    try {
      final result = await _client.correct(
        GemmaCorrectionRequest(
          modelPath: modelPath,
          modelId: config.modelId,
          instructions: config.instructions,
          transcript: rawText,
          timeoutMs: config.timeoutMs,
        ),
      );
      if (_disposed) {
        return;
      }
      final corrected = validateCorrectedTranscript(
        original: rawText,
        candidate: result.correctedText,
      );
      final correctedPath = _correctedPathForRaw(job.rawPath);
      await _atomicWriteText(correctedPath, corrected);
      final pipelineTotalMs = DateTime.now()
          .toUtc()
          .difference(job.queuedAt)
          .inMilliseconds;
      final metadataPath = _metadataPathForRaw(job.rawPath);
      await _atomicWriteJson(metadataPath, <String, Object>{
        'version': 1,
        'segment': job.segmentId,
        'stt': <String, Object>{
          'model': job.sttModel,
          'provider': job.sttProvider,
          'audioMs': job.audioMs,
          'decodeMs': job.sttDecodeMs,
          'totalMs': job.sttTotalMs,
        },
        'correction': <String, Object>{
          'model': config.modelId,
          'runtime': 'litertlm-0.14.0',
          'provider': result.provider,
          'queueMs': queueMs,
          'engineLoadMs': result.engineLoadMs,
          'inferenceMs': result.inferenceMs,
          'totalMs': result.totalMs,
          'timeToFirstTokenMs': result.timeToFirstTokenMs,
          'prefillTokensPerSecond': result.prefillTokensPerSecond,
          'decodeTokensPerSecond': result.decodeTokensPerSecond,
        },
        'pipelineTotalMs': pipelineTotalMs,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      });
      _pending.remove(job.segmentId);
      await _persistPending();
      activeProvider = result.provider;
      state = 'ready';
      onStatus(
        '[WorkBench][Correction] state=completed segment=${job.segmentId} '
        'model=${config.modelId} provider=${result.provider} '
        'queue_ms=$queueMs engine_load_ms=${result.engineLoadMs} '
        'inference_ms=${result.inferenceMs} correction_ms=${result.totalMs} '
        'stt_decode_ms=${job.sttDecodeMs} stt_total_ms=${job.sttTotalMs} '
        'pipeline_total_ms=$pipelineTotalMs '
        'ttft_ms=${result.timeToFirstTokenMs} '
        'prefill_tps=${result.prefillTokensPerSecond.toStringAsFixed(1)} '
        'decode_tps=${result.decodeTokensPerSecond.toStringAsFixed(1)} '
        'pending=${_pending.length}',
      );
      onCorrected(
        CorrectedTranscriptResult(
          segmentId: job.segmentId,
          originalText: rawText,
          correctedText: corrected,
          correctedPath: correctedPath,
          provider: result.provider,
          queueMs: queueMs,
          engineLoadMs: result.engineLoadMs,
          inferenceMs: result.inferenceMs,
          correctionTotalMs: result.totalMs,
          pipelineTotalMs: pipelineTotalMs,
        ),
      );
    } on Object catch (error) {
      await _retry(job, error);
    }
  }

  Future<void> _retry(
    TranscriptCorrectionJob job,
    Object error, {
    Duration? minimumDelay,
  }) async {
    if (_disposed) {
      return;
    }
    final attempt = job.attempts + 1;
    final backoff = switch (attempt) {
      1 => const Duration(seconds: 1),
      2 => const Duration(seconds: 5),
      3 => const Duration(seconds: 30),
      _ => const Duration(minutes: 5),
    };
    final delay = minimumDelay != null && minimumDelay > backoff
        ? minimumDelay
        : backoff;
    final retried = job.retryAfter(delay);
    _pending[job.segmentId] = retried;
    await _persistPending();
    state = 'degraded';
    onStatus(
      '[WorkBench][Correction] state=failed segment=${job.segmentId} '
      'attempt=$attempt retry_ms=${delay.inMilliseconds} '
      'error=${_oneLine(error)} raw=preserved',
      isError: true,
    );
  }

  Future<void> _restorePending() async {
    final directory = Directory(speechPath);
    await directory.create(recursive: true);
    final ledger = File('$speechPath/pending-corrections.json');
    if (await ledger.exists()) {
      try {
        final decoded = jsonDecode(await ledger.readAsString());
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final job = TranscriptCorrectionJob.fromJson(
              entry.key,
              entry.value,
            );
            if (job != null) {
              _pending[entry.key] = job;
            }
          }
        }
      } on Object catch (error) {
        onStatus(
          '[WorkBench][Correction] state=ledger_rebuild '
          'error=${_oneLine(error)}',
          isError: true,
        );
      }
    }
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.raw.txt')) {
        continue;
      }
      final id = entity.path
          .split(Platform.pathSeparator)
          .last
          .replaceFirst(RegExp(r'\.raw\.txt$'), '');
      if (await File(_correctedPathForRaw(entity.path)).exists()) {
        _pending.remove(id);
      } else {
        final queuedAt = (await entity.lastModified()).toUtc();
        _pending.putIfAbsent(
          id,
          () => TranscriptCorrectionJob(
            segmentId: id,
            rawPath: entity.path,
            sttModel: 'recovered',
            sttProvider: 'unknown',
            audioMs: 0,
            sttDecodeMs: 0,
            sttTotalMs: 0,
            queuedAt: queuedAt,
          ),
        );
      }
    }
    _pending.removeWhere(
      (_, job) =>
          !File(job.rawPath).existsSync() ||
          File(_correctedPathForRaw(job.rawPath)).existsSync(),
    );
    await _persistPending();
    if (_pending.isNotEmpty) {
      onStatus(
        '[WorkBench][Correction] state=jobs_recovered '
        'pending=${_pending.length}',
      );
    }
  }

  Future<void> _persistPending() async {
    final ledger = File('$speechPath/pending-corrections.json');
    final partial = File('${ledger.path}.part');
    final value = <String, Object>{
      for (final entry in _pending.entries) entry.key: entry.value.toJson(),
    };
    await partial.writeAsString(jsonEncode(value), flush: true);
    await partial.rename(ledger.path);
  }

  static String validateCorrectedTranscript({
    required String original,
    required String candidate,
  }) {
    final corrected = candidate.trim();
    if (corrected.isEmpty) {
      throw const FormatException('The corrected transcript is empty.');
    }
    final maximumLength = original.length * 2 + 256;
    if (corrected.length > maximumLength) {
      throw const FormatException(
        'The corrected transcript expanded beyond the safety limit.',
      );
    }
    final protectedPattern = RegExp(
      r'(?:--?[A-Za-z0-9][A-Za-z0-9_-]*|'
      r'(?:/|[A-Za-z]:\\)[^\s]+|'
      r'\b\d+(?:[.:/-]\d+)*\b)',
    );
    final correctedLower = corrected.toLowerCase();
    for (final match in protectedPattern.allMatches(original)) {
      final token = match.group(0);
      if (token != null && !correctedLower.contains(token.toLowerCase())) {
        throw FormatException(
          'The correction removed protected token "$token".',
        );
      }
    }
    return corrected;
  }

  static Future<void> _atomicWriteText(String path, String value) async {
    final partial = File('$path.part');
    await partial.writeAsString('$value\n', flush: true);
    await partial.rename(path);
  }

  static Future<void> _atomicWriteJson(
    String path,
    Map<String, Object> value,
  ) async {
    final partial = File('$path.part');
    await partial.writeAsString(jsonEncode(value), flush: true);
    await partial.rename(path);
  }

  Future<void> dispose() async {
    _disposed = true;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    await _client.releaseEngine();
  }

  Future<void> releaseIdleEngine() async {
    if (!_disposed && state != 'processing') {
      await _client.releaseEngine();
      state = 'idle';
      onStatus(
        '[WorkBench][Correction] state=engine_released reason=memory_pressure',
      );
    }
  }

  static String _correctedPathForRaw(String rawPath) =>
      rawPath.replaceFirst(RegExp(r'\.raw\.txt$'), '.corrected.txt');

  static String _metadataPathForRaw(String rawPath) =>
      rawPath.replaceFirst(RegExp(r'\.raw\.txt$'), '.transcript.json');

  static String _oneLine(Object value) {
    final line = '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= 500 ? line : line.substring(0, 500);
  }
}
