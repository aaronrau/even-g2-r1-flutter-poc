import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'nnapi_attestation.dart';

typedef VadStatusSink = void Function(String message, {bool isError});
typedef SpeechSegmentSink = void Function(String id, String wavPath);

const Duration vadPreRollDuration = Duration(seconds: 2);
const Duration vadDetectorSilenceDuration = Duration(milliseconds: 500);
const Duration vadTranscriptionDelay = Duration(milliseconds: 1250);
const Duration vadTotalSilenceDuration = Duration(milliseconds: 1750);

final class VadEndpointBuffer {
  VadEndpointBuffer({required int sampleRate, required Duration duration})
    : assert(sampleRate > 0),
      assert(duration > Duration.zero),
      _sampleRate = sampleRate,
      _targetSamples =
          sampleRate *
          duration.inMilliseconds ~/
          Duration.millisecondsPerSecond;

  final int _sampleRate;
  final int _targetSamples;
  int _remainingSamples = -1;
  int _capturedSamples = 0;

  bool get isActive => _remainingSamples >= 0;
  int get capturedMilliseconds =>
      _capturedSamples * Duration.millisecondsPerSecond ~/ _sampleRate;

  bool begin(int chunkSamples) {
    assert(chunkSamples >= 0);
    _capturedSamples = chunkSamples;
    _remainingSamples = _targetSamples - chunkSamples;
    return _remainingSamples <= 0;
  }

  bool add(int chunkSamples) {
    assert(chunkSamples >= 0);
    if (!isActive) {
      return false;
    }
    _capturedSamples += chunkSamples;
    _remainingSamples -= chunkSamples;
    return _remainingSamples <= 0;
  }

  void reset() {
    _remainingSamples = -1;
    _capturedSamples = 0;
  }
}

final class VadPreRollBuffer {
  VadPreRollBuffer({required this.maximumBytes}) : assert(maximumBytes > 0);

  final int maximumBytes;
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _sizeBytes = 0;

  Iterable<Uint8List> get chunks => _chunks;
  int get sizeBytes => _sizeBytes;

  void add(Uint8List pcm) {
    final stable = Uint8List.fromList(pcm);
    _chunks.addLast(stable);
    _sizeBytes += stable.length;
    while (_sizeBytes > maximumBytes && _chunks.isNotEmpty) {
      _sizeBytes -= _chunks.removeFirst().length;
    }
  }

  int clear() {
    final clearedBytes = _sizeBytes;
    _chunks.clear();
    _sizeBytes = 0;
    return clearedBytes;
  }
}

final class VadSupervisor {
  VadSupervisor({
    required this.modelPath,
    required this.outputPath,
    required this.providers,
    required this.onSegment,
    required this.onStatus,
  });

  final String modelPath;
  final String outputPath;
  final List<String> providers;
  final SpeechSegmentSink onSegment;
  final VadStatusSink onStatus;

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

  bool get isReady => _commands != null && (_ready?.isCompleted ?? false);

  Future<String> start() async {
    await Directory(outputPath).create(recursive: true);
    await _spawn();
    return _ready!.future.timeout(const Duration(seconds: 20));
  }

  void acceptPcm(Uint8List pcm16) {
    if (_disposed || pcm16.isEmpty) {
      return;
    }
    _commands?.send(<String, Object>{
      'type': 'pcm',
      'bytes': TransferableTypedData.fromList(<Uint8List>[pcm16]),
    });
  }

  void flush() {
    _commands?.send(<String, Object>{'type': 'flush'});
  }

  Future<void> restartForTest() async {
    if (_disposed || _isolate == null) {
      return;
    }
    onStatus('[WorkBench][VAD] state=restarting reason=diagnostic');
    _isolate!.kill(priority: Isolate.immediate);
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
        '[WorkBench][VAD] state=failed error=${_oneLine(error)}',
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
      _vadWorker,
      <String, Object>{
        'events': _events!.sendPort,
        'modelPath': modelPath,
        'outputPath': outputPath,
        'providers': providers,
      },
      debugName: 'workbench-vad',
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
          '[WorkBench][VAD] state=loading provider=${event['provider']}',
        );
        return;
      case 'provider_failed':
        onStatus(
          '[WorkBench][VAD] state=provider_failed '
          'provider=${event['provider']} '
          'error=${_oneLine(event['error'])}',
        );
        return;
      case 'provider_attested':
        onStatus(
          '[WorkBench][Inference] state=attested workload=vad '
          'provider=nnapi nnapi_nodes=${event['nnapiNodes']} '
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
          '[WorkBench][VAD] state=ready provider=$activeProvider '
          'recovered=$recovered',
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.complete(activeProvider);
        }
        return;
      case 'speech_started':
        onStatus(
          '[WorkBench][VAD] state=speech_started segment=${event['id']} '
          'pre_roll_ms=${event['preRollMs']} '
          'pre_roll_bytes=${event['preRollBytes']}',
        );
        return;
      case 'speech_ending':
        onStatus(
          '[WorkBench][VAD] state=speech_ending segment=${event['id']} '
          'delay_ms=${event['delayMs']}',
        );
        return;
      case 'buffer_cleared':
        onStatus(
          '[WorkBench][VAD] state=buffer_cleared segment=${event['id']} '
          'bytes=${event['bytes']} next=ready',
        );
        return;
      case 'segment':
        final id = event['id']! as String;
        onStatus(
          '[WorkBench][VAD] state=speech_ended segment=$id '
          'audio_ms=${event['endpointAudioMs']}',
        );
        onSegment(id, event['path']! as String);
        return;
      case 'error':
        final error = StateError('${event['message']}');
        onStatus(
          '[WorkBench][VAD] state=failed '
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
    _restarting = true;
    onStatus('[WorkBench][VAD] state=restarting');
    _restartTimer = Timer(const Duration(seconds: 1), () {
      _restartTimer = null;
      unawaited(
        _closePorts().then((_) => _spawn()).catchError((Object error) {
          onStatus(
            '[WorkBench][VAD] state=failed '
            'restart_error=${_oneLine(error)}',
            isError: true,
          );
          _scheduleRestart();
        }),
      );
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

void _vadWorker(Map<String, Object> bootstrap) {
  const sampleRate = 16000;
  final preRollBytes =
      sampleRate *
      2 *
      vadPreRollDuration.inMilliseconds ~/
      Duration.millisecondsPerSecond;
  const maximumSegmentSamples = sampleRate * 60 * 15;

  final events = bootstrap['events']! as SendPort;
  final modelPath = bootstrap['modelPath']! as String;
  final outputPath = bootstrap['outputPath']! as String;
  final providers = (bootstrap['providers']! as List<Object?>).cast<String>();
  final commands = ReceivePort();
  final preRoll = VadPreRollBuffer(maximumBytes: preRollBytes);
  final endpoint = VadEndpointBuffer(
    sampleRate: sampleRate,
    duration: vadTranscriptionDelay,
  );
  RandomAccessFile? segmentFile;
  String? segmentId;
  String? partialPath;
  var segmentSamples = 0;
  var wasDetected = false;

  void writeHeader(RandomAccessFile file, int samples) {
    final dataBytes = samples * 2;
    final header = ByteData(44);
    void ascii(int offset, String value) {
      header.buffer.asUint8List().setAll(offset, value.codeUnits);
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);
    file.setPositionSync(0);
    file.writeFromSync(header.buffer.asUint8List());
  }

  void beginSegment() {
    final now = DateTime.now().toUtc();
    final preRollBytesAtStart = preRoll.sizeBytes;
    segmentId =
        '${now.microsecondsSinceEpoch}-${now.toIso8601String().substring(11, 19).replaceAll(':', '')}';
    partialPath = '$outputPath/$segmentId.part.wav';
    segmentFile = File(partialPath!).openSync(mode: FileMode.write);
    writeHeader(segmentFile!, 0);
    segmentSamples = 0;
    for (final chunk in preRoll.chunks) {
      segmentFile!.writeFromSync(chunk);
      segmentSamples += chunk.length ~/ 2;
    }
    endpoint.reset();
    events.send(<String, Object>{
      'type': 'speech_started',
      'id': segmentId!,
      'preRollMs':
          preRollBytesAtStart *
          Duration.millisecondsPerSecond ~/
          (sampleRate * 2),
      'preRollBytes': preRollBytesAtStart,
    });
  }

  void finishSegment({bool preserveEndpointPreRoll = false}) {
    final file = segmentFile;
    final id = segmentId;
    final part = partialPath;
    if (file == null || id == null || part == null) {
      return;
    }
    final endpointAudioMs = endpoint.capturedMilliseconds;
    writeHeader(file, segmentSamples);
    file.flushSync();
    file.closeSync();
    final finalPath = part.replaceFirst('.part.wav', '.wav');
    File(part).renameSync(finalPath);
    segmentFile = null;
    segmentId = null;
    partialPath = null;
    segmentSamples = 0;
    endpoint.reset();
    if (!preserveEndpointPreRoll) {
      final clearedBytes = preRoll.clear();
      events.send(<String, Object>{
        'type': 'buffer_cleared',
        'id': id,
        'bytes': clearedBytes,
      });
    }
    events.send(<String, Object>{
      'type': 'segment',
      'id': id,
      'path': finalPath,
      'endpointAudioMs': endpointAudioMs,
    });
  }

  void recoverInterruptedSegments() {
    final directory = Directory(outputPath);
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.part.wav')) {
        continue;
      }
      if (entity.lengthSync() <= 44) {
        entity.deleteSync();
        continue;
      }
      final file = entity.openSync(mode: FileMode.append);
      final samples = (entity.lengthSync() - 44) ~/ 2;
      writeHeader(file, samples);
      file.flushSync();
      file.closeSync();
      final id = entity.uri.pathSegments.last.replaceFirst('.part.wav', '');
      final recoveredPath = entity.path.replaceFirst(
        '.part.wav',
        '.recovered.wav',
      );
      entity.renameSync(recoveredPath);
      events.send(<String, Object>{
        'type': 'segment',
        'id': '$id-recovered',
        'path': recoveredPath,
        'endpointAudioMs': 0,
      });
    }
  }

  try {
    sherpa.initBindings();
    sherpa.VoiceActivityDetector createVad(String provider) {
      return sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: modelPath,
            threshold: 0.5,
            minSilenceDuration:
                vadDetectorSilenceDuration.inMilliseconds /
                Duration.millisecondsPerSecond,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 900,
          ),
          sampleRate: sampleRate,
          numThreads: 1,
          provider: provider,
          debug: false,
        ),
        bufferSizeInSeconds: 30,
      );
    }

    sherpa.VoiceActivityDetector? vad;
    String? activeProvider;
    for (final provider in providers) {
      events.send(<String, Object>{
        'type': 'provider_attempt',
        'provider': provider,
      });
      sherpa.VoiceActivityDetector? candidate;
      NnapiProfileProbe? probe;
      try {
        if (provider == 'nnapi') {
          probe = NnapiProfileProbe.create(workload: 'vad');
        }
        candidate = createVad(probe?.provider ?? provider);
        candidate.acceptWaveform(Float32List(512));
        candidate.isDetected();
        candidate.reset();
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
            'nnapiNodes': attestation.nnapiNodeExecutions,
            'cpuNodes': attestation.cpuNodeExecutions,
            'otherNodes': attestation.otherNodeExecutions,
            'nnapiMicros': attestation.nnapiDurationMicros,
            'cpuMicros': attestation.cpuDurationMicros,
          });
          candidate = createVad(provider);
          candidate.acceptWaveform(Float32List(512));
          candidate.isDetected();
          candidate.reset();
        }
        vad = candidate;
        activeProvider = provider;
        break;
      } catch (error) {
        candidate?.free();
        probe?.discard();
        events.send(<String, Object>{
          'type': 'provider_failed',
          'provider': provider,
          'error': '$error',
        });
      }
    }

    final detector = vad;
    final selectedProvider = activeProvider;
    if (detector == null || selectedProvider == null) {
      throw StateError('No compatible ONNX execution provider could load VAD.');
    }

    commands.listen((Object? message) {
      if (message is! Map<Object?, Object?>) {
        return;
      }
      switch (message['type']) {
        case 'pcm':
          final pcm = (message['bytes']! as TransferableTypedData)
              .materialize()
              .asUint8List();
          final samples = _pcm16ToFloat(pcm);
          detector.acceptWaveform(samples);
          final detected = detector.isDetected();
          if (detected && segmentFile == null) {
            beginSegment();
          }
          if (segmentFile != null) {
            segmentFile!.writeFromSync(pcm);
            segmentSamples += pcm.length ~/ 2;
            if (detected) {
              endpoint.reset();
            } else if (wasDetected) {
              final chunkSamples = pcm.length ~/ 2;
              final endpointComplete = endpoint.begin(chunkSamples);
              final clearedBytes = preRoll.clear();
              events.send(<String, Object>{
                'type': 'speech_ending',
                'id': segmentId!,
                'delayMs': vadTranscriptionDelay.inMilliseconds,
              });
              events.send(<String, Object>{
                'type': 'buffer_cleared',
                'id': segmentId!,
                'bytes': clearedBytes,
              });
              if (endpointComplete) {
                finishSegment(preserveEndpointPreRoll: true);
              }
            } else if (endpoint.isActive) {
              final chunkSamples = pcm.length ~/ 2;
              if (endpoint.add(chunkSamples)) {
                finishSegment(preserveEndpointPreRoll: true);
              }
            }
            if (segmentSamples >= maximumSegmentSamples) {
              finishSegment();
              if (detected) {
                beginSegment();
              }
            }
          }
          preRoll.add(pcm);
          wasDetected = detected;
          return;
        case 'flush':
          detector.flush();
          finishSegment();
          wasDetected = false;
          return;
        case 'close':
          detector.flush();
          finishSegment();
          detector.free();
          commands.close();
          return;
      }
    });
    events.send(<String, Object>{
      'type': 'commands',
      'port': commands.sendPort,
    });
    recoverInterruptedSegments();
    events.send(<String, Object>{
      'type': 'ready',
      'provider': selectedProvider,
    });
  } catch (error) {
    events.send(<String, Object>{'type': 'error', 'message': '$error'});
    rethrow;
  }
}

Float32List _pcm16ToFloat(Uint8List pcm) {
  final input = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = input.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return samples;
}
