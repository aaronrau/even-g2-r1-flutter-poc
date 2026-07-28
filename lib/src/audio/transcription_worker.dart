import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'nnapi_attestation.dart';
import 'speech_model.dart';

typedef TranscriptionStatusSink = void Function(String message, {bool isError});
typedef TranscriptSink = void Function(TranscriptionResult result);

final class TranscriptionResult {
  const TranscriptionResult({
    required this.segmentId,
    required this.text,
    required this.transcriptPath,
    required this.model,
    required this.provider,
    required this.audioMs,
    required this.decodeMs,
    required this.totalMs,
    required this.queuedAt,
    required this.routeEligible,
  });

  final String segmentId;
  final String text;
  final String transcriptPath;
  final String model;
  final String provider;
  final int audioMs;
  final int decodeMs;
  final int totalMs;
  final DateTime queuedAt;
  final bool routeEligible;
}

final class TranscriptionRecoveryTracker {
  final Set<String> _restoredJobIds = <String>{};

  void restore(Iterable<String> segmentIds) {
    _restoredJobIds.addAll(segmentIds);
  }

  void markLive(String segmentId) {
    _restoredJobIds.remove(segmentId);
  }

  bool takeRouteEligibility(String segmentId) {
    return !_restoredJobIds.remove(segmentId);
  }
}

final class TranscriptionSupervisor {
  TranscriptionSupervisor({
    required this.model,
    required this.speechPath,
    required this.providers,
    required this.onTranscript,
    required this.onStatus,
  });

  final TranscriptionModelPaths model;
  final String speechPath;
  final List<String> providers;
  final TranscriptSink onTranscript;
  final TranscriptionStatusSink onStatus;

  final LinkedHashMap<String, String> _pending =
      LinkedHashMap<String, String>();
  final Map<String, Timer> _jobRetryTimers = <String, Timer>{};
  final Map<String, int> _jobRetryAttempts = <String, int>{};
  final Map<String, DateTime> _jobQueuedAt = <String, DateTime>{};
  final TranscriptionRecoveryTracker _recoveryTracker =
      TranscriptionRecoveryTracker();
  ReceivePort? _events;
  ReceivePort? _errors;
  ReceivePort? _exit;
  StreamSubscription<Object?>? _eventSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  SendPort? _commands;
  Isolate? _isolate;
  Completer<String>? _ready;
  Timer? _restartTimer;
  bool _disposed = false;
  bool _restarting = false;
  String? activeProvider;

  Future<String> start() async {
    _restorePending();
    await _spawn();
    return _ready!.future.timeout(const Duration(minutes: 3));
  }

  void transcribe(String segmentId, String wavPath) {
    if (_disposed) {
      return;
    }
    _recoveryTracker.markLive(segmentId);
    _pending[segmentId] = wavPath;
    _jobQueuedAt.putIfAbsent(segmentId, () => DateTime.now().toUtc());
    _persistPending();
    onStatus(
      '[WorkBench][Transcription] state=queued segment=$segmentId '
      'pending=${_pending.length}',
    );
    _sendJob(segmentId, wavPath);
  }

  Future<void> restartForTest() async {
    if (_disposed || _isolate == null) {
      return;
    }
    _restarting = true;
    onStatus('[WorkBench][Transcription] state=restarting reason=diagnostic');
    _isolate!.kill(priority: Isolate.immediate);
  }

  void _sendJob(String segmentId, String wavPath) {
    _commands?.send(<String, Object>{
      'type': 'transcribe',
      'id': segmentId,
      'path': wavPath,
    });
  }

  Future<void> _spawn() async {
    _commands = null;
    activeProvider = null;
    _ready = Completer<String>();
    _events = ReceivePort();
    _errors = ReceivePort();
    _exit = ReceivePort();
    _eventSubscription = _events!.listen(_handleEvent);
    _errorSubscription = _errors!.listen((Object? error) {
      onStatus(
        '[WorkBench][Transcription] state=failed error=${_oneLine(error)}',
        isError: true,
      );
    });
    _exitSubscription = _exit!.listen((_) {
      _commands = null;
      _isolate = null;
      if (!_disposed) {
        _scheduleRestart();
      }
    });
    _isolate = await Isolate.spawn<Map<String, Object>>(
      _transcriptionWorker,
      <String, Object>{
        'events': _events!.sendPort,
        'model': model.toMessage(),
        'providers': providers,
      },
      debugName: 'workbench-transcription',
      errorsAreFatal: true,
      onError: _errors!.sendPort,
      onExit: _exit!.sendPort,
    );
  }

  void _handleEvent(Object? event) {
    if (event is! Map<Object?, Object?>) {
      return;
    }
    switch (event['type']) {
      case 'commands':
        _commands = event['port']! as SendPort;
        return;
      case 'provider_attempt':
        onStatus(
          '[WorkBench][Transcription] state=loading '
          'model=${event['model']} provider=${event['provider']}',
        );
        return;
      case 'provider_failed':
        onStatus(
          '[WorkBench][Transcription] state=provider_failed '
          'model=${event['model']} provider=${event['provider']} '
          'error=${_oneLine(event['error'])}',
        );
        return;
      case 'provider_attested':
        onStatus(
          '[WorkBench][Inference] state=attested '
          'workload=stt model=${event['model']} provider=nnapi '
          'nnapi_nodes=${event['nnapiNodes']} '
          'cpu_nodes=${event['cpuNodes']} '
          'other_nodes=${event['otherNodes']} '
          'nnapi_us=${event['nnapiMicros']} '
          'cpu_us=${event['cpuMicros']}',
        );
        return;
      case 'ready':
        activeProvider = event['provider']! as String;
        final recovered = _restarting;
        _restarting = false;
        onStatus(
          '[WorkBench][Transcription] state=ready '
          'model=${event['model']} provider=$activeProvider '
          'recovered=$recovered',
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.complete(activeProvider);
        }
        for (final entry in _pending.entries) {
          _sendJob(entry.key, entry.value);
        }
        return;
      case 'processing':
        onStatus(
          '[WorkBench][Transcription] state=processing segment=${event['id']}',
        );
        return;
      case 'result':
        final id = event['id']! as String;
        final text = event['text']! as String;
        final routeEligible = _recoveryTracker.takeRouteEligibility(id);
        final queuedAt = _jobQueuedAt.remove(id) ?? DateTime.now().toUtc();
        final totalMs = DateTime.now()
            .toUtc()
            .difference(queuedAt)
            .inMilliseconds;
        _jobRetryTimers.remove(id)?.cancel();
        _jobRetryAttempts.remove(id);
        _pending.remove(id);
        _persistPending();
        onStatus('[WorkBench][Transcript][FINAL] segment=$id text=$text');
        onStatus(
          '[WorkBench][Transcription] state=completed segment=$id '
          'model=${event['model']} provider=${event['provider']} '
          'audio_ms=${event['audioMs']} '
          'decode_ms=${event['decodeMs']} total_ms=$totalMs',
        );
        onTranscript(
          TranscriptionResult(
            segmentId: id,
            text: text,
            transcriptPath: event['transcriptPath']! as String,
            model: event['model']! as String,
            provider: event['provider']! as String,
            audioMs: event['audioMs']! as int,
            decodeMs: event['decodeMs']! as int,
            totalMs: totalMs,
            queuedAt: queuedAt,
            routeEligible: routeEligible,
          ),
        );
        return;
      case 'job_error':
        final id = event['id']! as String;
        onStatus(
          '[WorkBench][Transcription] state=job_failed '
          'segment=$id error=${_oneLine(event['error'])}',
          isError: true,
        );
        _scheduleJobRetry(id);
        return;
      case 'fatal':
        final error = StateError('${event['error']}');
        onStatus(
          '[WorkBench][Transcription] state=failed '
          'error=${_oneLine(error)}',
          isError: true,
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.completeError(error);
        }
        return;
    }
  }

  void _scheduleRestart() {
    if (_disposed || _restartTimer != null) {
      return;
    }
    if (!_restarting) {
      _restarting = true;
      onStatus(
        '[WorkBench][Transcription] state=restarting '
        'pending=${_pending.length}',
      );
    }
    _restartTimer = Timer(const Duration(seconds: 1), () {
      _restartTimer = null;
      unawaited(
        _closePorts().then((_) => _spawn()).catchError((Object error) {
          onStatus(
            '[WorkBench][Transcription] state=failed '
            'restart_error=${_oneLine(error)}',
            isError: true,
          );
          _scheduleRestart();
        }),
      );
    });
  }

  void _restorePending() {
    final directory = Directory(speechPath)..createSync(recursive: true);
    final ledger = File('$speechPath/pending-transcriptions.json');
    if (ledger.existsSync()) {
      try {
        final decoded = jsonDecode(ledger.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is String) {
              _pending[entry.key] = entry.value! as String;
            }
          }
        }
      } catch (error) {
        onStatus(
          '[WorkBench][Transcription] state=ledger_rebuild '
          'error=${_oneLine(error)}',
          isError: true,
        );
      }
    }

    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.wav')) {
        continue;
      }
      final id = entity.uri.pathSegments.last.replaceFirst(
        RegExp(r'\.wav$'),
        '',
      );
      if (_hasTranscriptForAudio(entity.path)) {
        _pending.remove(id);
      } else {
        _pending[id] = entity.path;
        _jobQueuedAt.putIfAbsent(id, () => entity.lastModifiedSync().toUtc());
      }
    }
    _pending.removeWhere(
      (_, path) => !File(path).existsSync() || _hasTranscriptForAudio(path),
    );
    _recoveryTracker.restore(_pending.keys);
    _persistPending();
    if (_pending.isNotEmpty) {
      onStatus(
        '[WorkBench][Transcription] state=jobs_recovered '
        'pending=${_pending.length}',
      );
    }
  }

  void _persistPending() {
    try {
      final ledger = File('$speechPath/pending-transcriptions.json');
      final partial = File('${ledger.path}.part');
      partial.writeAsStringSync(jsonEncode(_pending), flush: true);
      partial.renameSync(ledger.path);
    } catch (error) {
      onStatus(
        '[WorkBench][Transcription] state=ledger_failed '
        'error=${_oneLine(error)}',
        isError: true,
      );
    }
  }

  void _scheduleJobRetry(String id) {
    final path = _pending[id];
    if (_disposed || path == null || _jobRetryTimers.containsKey(id)) {
      return;
    }
    final attempt = (_jobRetryAttempts[id] ?? 0) + 1;
    _jobRetryAttempts[id] = attempt;
    if (attempt > 3) {
      onStatus(
        '[WorkBench][Transcription] state=job_preserved '
        'segment=$id action=manual_restart',
        isError: true,
      );
      return;
    }
    final delay = switch (attempt) {
      1 => const Duration(seconds: 1),
      2 => const Duration(seconds: 5),
      _ => const Duration(seconds: 30),
    };
    _jobRetryTimers[id] = Timer(delay, () {
      _jobRetryTimers.remove(id);
      final pendingPath = _pending[id];
      if (!_disposed && pendingPath != null) {
        onStatus(
          '[WorkBench][Transcription] state=job_retry '
          'segment=$id attempt=$attempt',
        );
        _sendJob(id, pendingPath);
      }
    });
  }

  Future<void> _closePorts() async {
    await _eventSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _exitSubscription?.cancel();
    _eventSubscription = null;
    _errorSubscription = null;
    _exitSubscription = null;
    _events?.close();
    _errors?.close();
    _exit?.close();
    _events = null;
    _errors = null;
    _exit = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _restartTimer?.cancel();
    for (final timer in _jobRetryTimers.values) {
      timer.cancel();
    }
    _jobRetryTimers.clear();
    _commands?.send(<String, Object>{'type': 'close'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    await _closePorts();
  }

  String _oneLine(Object? value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _transcriptPathForAudio(String path) =>
    path.replaceFirst(RegExp(r'\.(?:recovered\.)?wav$'), '.raw.txt');

bool _hasTranscriptForAudio(String path) {
  if (File(_transcriptPathForAudio(path)).existsSync()) {
    return true;
  }
  final legacy = path.replaceFirst(RegExp(r'\.(?:recovered\.)?wav$'), '.txt');
  return File(legacy).existsSync();
}

void _transcriptionWorker(Map<String, Object> bootstrap) {
  final events = bootstrap['events']! as SendPort;
  final model = (bootstrap['model']! as Map<Object?, Object?>)
      .cast<String, Object>();
  final modelId = model['id']! as String;
  final architecture = model['architecture']! as String;
  final modelPath = model['model']! as String;
  final encoder = model['encoder']! as String;
  final decoder = model['decoder']! as String;
  final joiner = model['joiner']! as String;
  final tokens = model['tokens']! as String;
  final providers = (bootstrap['providers']! as List<Object?>).cast<String>();
  final commands = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  String? activeProvider;

  sherpa.OfflineRecognizer createRecognizer(String provider) {
    final modelConfig = switch (architecture) {
      'whisper' => sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: encoder,
          decoder: decoder,
          language: 'en',
          task: 'transcribe',
        ),
        tokens: tokens,
        numThreads: provider == 'cpu' ? 2 : 1,
        debug: false,
        provider: provider,
        modelType: 'whisper',
      ),
      'nemoCtc' => sherpa.OfflineModelConfig(
        nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: modelPath),
        tokens: tokens,
        numThreads: provider == 'cpu' ? 2 : 1,
        debug: false,
        provider: provider,
      ),
      'transducer' => sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: encoder,
          decoder: decoder,
          joiner: joiner,
        ),
        tokens: tokens,
        numThreads: provider == 'cpu' ? 2 : 1,
        debug: false,
        provider: provider,
      ),
      _ => throw UnsupportedError(
        'Unsupported speech model architecture "$architecture".',
      ),
    };
    return sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(model: modelConfig),
    );
  }

  void warmUp(sherpa.OfflineRecognizer candidate) {
    final stream = candidate.createStream();
    try {
      stream.acceptWaveform(samples: Float32List(16000), sampleRate: 16000);
      candidate.decode(stream);
      candidate.getResult(stream);
    } finally {
      stream.free();
    }
  }

  try {
    sherpa.initBindings();
    for (final provider in providers) {
      events.send(<String, Object>{
        'type': 'provider_attempt',
        'model': modelId,
        'provider': provider,
      });
      sherpa.OfflineRecognizer? candidate;
      NnapiProfileProbe? probe;
      try {
        if (provider == 'nnapi') {
          probe = NnapiProfileProbe.create(workload: 'stt-$modelId');
        }
        candidate = createRecognizer(probe?.provider ?? provider);
        warmUp(candidate);
        if (probe != null) {
          candidate.free();
          candidate = null;
          final attestation = probe.finish();
          probe = null;
          if (!attestation.usedNnapiHardware) {
            throw StateError(attestation.rejectionReason);
          }
          events.send(<String, Object>{
            'type': 'provider_attested',
            'model': modelId,
            'nnapiNodes': attestation.nnapiNodeExecutions,
            'cpuNodes': attestation.cpuNodeExecutions,
            'otherNodes': attestation.otherNodeExecutions,
            'nnapiMicros': attestation.nnapiDurationMicros,
            'cpuMicros': attestation.cpuDurationMicros,
          });
          candidate = createRecognizer(provider);
          warmUp(candidate);
        }
        recognizer = candidate;
        activeProvider = provider;
        break;
      } catch (error) {
        candidate?.free();
        probe?.discard();
        events.send(<String, Object>{
          'type': 'provider_failed',
          'model': modelId,
          'provider': provider,
          'error': '$error',
        });
      }
    }

    if (recognizer == null || activeProvider == null) {
      events.send(<String, Object>{
        'type': 'fatal',
        'error': 'No compatible ONNX execution provider could load $modelId.',
      });
      commands.close();
      return;
    }
    final selectedProvider = activeProvider;

    commands.listen((Object? message) {
      if (message is! Map<Object?, Object?>) {
        return;
      }
      switch (message['type']) {
        case 'transcribe':
          final id = message['id']! as String;
          final path = message['path']! as String;
          events.send(<String, Object>{'type': 'processing', 'id': id});
          try {
            final wave = sherpa.readWave(path);
            if (wave.samples.isEmpty || wave.sampleRate != 16000) {
              throw StateError(
                'Expected non-empty 16 kHz PCM WAV; got '
                '${wave.samples.length} samples at ${wave.sampleRate} Hz.',
              );
            }
            final stream = recognizer!.createStream();
            String text;
            final stopwatch = Stopwatch()..start();
            try {
              stream.acceptWaveform(
                samples: wave.samples,
                sampleRate: wave.sampleRate,
              );
              recognizer.decode(stream);
              text = recognizer.getResult(stream).text.trim();
            } finally {
              stopwatch.stop();
              stream.free();
            }
            final audioMs = wave.samples.length * 1000 ~/ wave.sampleRate;
            final transcriptPath = _transcriptPathForAudio(path);
            final partial = File('$transcriptPath.part');
            partial.writeAsStringSync('$text\n', flush: true);
            final transcript = File(transcriptPath);
            if (transcript.existsSync()) {
              transcript.deleteSync();
            }
            partial.renameSync(transcriptPath);
            final jsonl = File('${File(path).parent.path}/transcripts.jsonl');
            jsonl.writeAsStringSync(
              '${jsonEncode(<String, Object>{'segment': id, 'audio': path, 'text': text, 'model': modelId, 'provider': selectedProvider, 'audioMs': audioMs, 'decodeMs': stopwatch.elapsedMilliseconds, 'completedAt': DateTime.now().toUtc().toIso8601String()})}\n',
              mode: FileMode.append,
              flush: true,
            );
            events.send(<String, Object>{
              'type': 'result',
              'id': id,
              'text': text,
              'model': modelId,
              'provider': selectedProvider,
              'audioMs': audioMs,
              'decodeMs': stopwatch.elapsedMilliseconds,
              'transcriptPath': transcriptPath,
            });
          } catch (error) {
            events.send(<String, Object>{
              'type': 'job_error',
              'id': id,
              'error': '$error',
            });
          }
          return;
        case 'close':
          recognizer?.free();
          commands.close();
          return;
      }
    });
    events.send(<String, Object>{
      'type': 'commands',
      'port': commands.sendPort,
    });
    events.send(<String, Object>{
      'type': 'ready',
      'model': modelId,
      'provider': selectedProvider,
    });
  } catch (error) {
    events.send(<String, Object>{'type': 'fatal', 'error': '$error'});
    rethrow;
  }
}
