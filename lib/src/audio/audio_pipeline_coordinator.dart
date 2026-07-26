import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../startup/startup_state.dart';
import 'capture_journal.dart';
import 'inference_capabilities.dart';
import 'lc3_decoder.dart';
import 'model_asset_store.dart';
import 'pcm_gain.dart';
import 'shared_audio_export_store.dart';
import 'speech_model.dart';
import 'transcript_turn_state.dart';
import 'transcription_worker.dart';
import 'vad_worker.dart';

typedef AudioPipelineLog =
    void Function(String source, String message, {bool isError});

final class AudioPipelineCoordinator {
  AudioPipelineCoordinator({
    required this.log,
    required this.onChanged,
    required this.onCaptureUnsafe,
    required SharedAudioExportStore sharedAudioExportStore,
    ModelAssetStore? modelStore,
    Lc3Decoder? decoder,
  }) : _modelStore = modelStore ?? ModelAssetStore(),
       _decoder = decoder ?? Lc3Decoder(),
       _sharedAudioExportStore = sharedAudioExportStore;

  static const int _maximumVadRecoveryBytes = 16000 * 2 * 30;

  final AudioPipelineLog log;
  final void Function() onChanged;
  final void Function() onCaptureUnsafe;
  final ModelAssetStore _modelStore;
  final Lc3Decoder _decoder;
  final SharedAudioExportStore _sharedAudioExportStore;
  final Queue<Uint8List> _vadRecovery = Queue<Uint8List>();
  final TranscriptTurnState _transcriptTurn = TranscriptTurnState();

  CaptureJournalSupervisor? _capture;
  VadSupervisor? _vad;
  TranscriptionSupervisor? _transcription;
  Future<void> _decodeTail = Future<void>.value();
  bool _initialized = false;
  bool _initialStartupComplete = false;
  bool _disposed = false;
  bool _vadWasReady = false;
  bool _modelSwitching = false;
  int _vadRecoveryBytes = 0;
  int _meterSamples = 0;
  double _meterSquareSum = 0;
  int _meterPeak = 0;
  DateTime? _meterStartedAt;
  SpeechModelDefinition _selectedModel = defaultSpeechModel();
  TranscriptionModelPaths? _transcriptionPaths;
  String? _speechPath;
  List<String>? _inferenceProviders;
  int _sharedExportOperations = 0;

  StartupSnapshot startup = const StartupSnapshot.starting();
  String? audioFolder;
  String? activeModelId;
  String? activeModelName;
  String? activeProvider;
  String? activeVadProvider;
  String? get lastTranscript => _transcriptTurn.visibleText;
  String? lastTranscriptPath;
  String? sharedExportError;
  int sharedExportedFiles = 0;
  int completedTranscripts = 0;

  bool get canConnect => startup.isReady;
  bool get isSwitchingModel => _modelSwitching;
  bool get isExportingSharedAudio => _sharedExportOperations > 0;
  String get selectedModelId => _selectedModel.id;

  Future<void> initialize({SpeechModelDefinition? transcriptionModel}) async {
    if (_initialized || _disposed) {
      return;
    }
    final requestedModel = transcriptionModel ?? _selectedModel;
    _initialized = true;
    try {
      _setStartup(StartupPhase.storage, 'Preparing safe local audio storage…');
      final paths = await _modelStore.prepare(
        transcriptionModel: requestedModel,
        onStatus: (message) {
          _setStartup(StartupPhase.storage, message);
        },
      );
      audioFolder = paths.audioRoot;

      _capture = CaptureJournalSupervisor(
        rootPath: '${paths.audioRoot}/journal',
        onCaptured: _decodeCaptured,
        onStatus: _pipelineStatus,
        onFatalBackpressure: onCaptureUnsafe,
      );
      await _capture!.start();

      _setStartup(StartupPhase.decoder, 'Checking the LC3 audio decoder…');
      await _decoder.initialize();
      log(
        'Pipeline',
        '[WorkBench][Decoder] state=ready sample_rate=16000 '
            'pcm_gain=${g2PcmGain}x',
      );

      _setStartup(
        StartupPhase.transcription,
        'Checking on-device acceleration…',
      );
      final capabilities = await InferenceCapabilities.detect();
      _inferenceProviders = capabilities.providers;
      log(
        'Pipeline',
        '[WorkBench][Inference] '
            'gpu_hardware=${capabilities.hasGpuHardware} '
            'nnapi_api=${capabilities.hasNnapiApi} '
            'providers=${capabilities.providers.join(',')} '
            'runtime=${capabilities.description}',
      );

      _setStartup(StartupPhase.vad, 'Loading voice activity detection…');
      _vad = VadSupervisor(
        modelPath: paths.vad,
        outputPath: '${paths.audioRoot}/speech',
        providers: capabilities.providers,
        onSegment: _onSpeechSegment,
        onStatus: _vadStatus,
      );
      activeVadProvider = await _vad!.start();
      _vadWasReady = true;

      _speechPath = '${paths.audioRoot}/speech';
      _transcription = TranscriptionSupervisor(
        model: paths.transcription,
        speechPath: _speechPath!,
        providers: capabilities.providers,
        onTranscript: _onTranscript,
        onStatus: _transcriptionStatus,
      );
      _transcriptionPaths = paths.transcription;
      activeModelId = paths.transcription.definition.id;
      activeModelName = paths.transcription.definition.displayName;
      activeProvider = await _transcription!.start();
      _selectedModel = requestedModel;

      _setStartup(
        StartupPhase.ready,
        'Local audio ready · $activeModelName · $activeProvider',
        provider: activeProvider,
      );
      log(
        'Pipeline',
        '[WorkBench][Pipeline] state=ready '
            'model=${paths.transcription.definition.id} '
            'stt_provider=$activeProvider '
            'vad_provider=$activeVadProvider',
      );
      _initialStartupComplete = true;
      if (_sharedAudioExportStore.hasSharedFolder) {
        unawaited(syncSharedAudioExport());
      }
    } catch (error, stackTrace) {
      _setStartup(
        StartupPhase.failed,
        'Local audio could not start: ${_oneLine(error)}',
      );
      log(
        'Pipeline',
        '[WorkBench][Pipeline] state=failed error=${_oneLine(error)} '
            'stack=${_oneLine(stackTrace)}',
        isError: true,
      );
      rethrow;
    }
  }

  void acceptLc3(Uint8List packet) {
    if (_disposed || !_initialized || packet.isEmpty) {
      return;
    }
    _capture?.accept(packet);
  }

  void _decodeCaptured(int sequence, Uint8List packet) {
    _decodeTail = _decodeTail.then((_) async {
      if (_disposed) {
        return;
      }
      try {
        final decoded = await _decoder.decode(packet);
        final pcm = applyG2PcmGain(decoded);
        _meterPcm(pcm);
        final vad = _vad;
        if (vad?.isReady ?? false) {
          vad!.acceptPcm(pcm);
          return;
        }
        _queueVadRecovery(pcm);
      } catch (error) {
        log(
          'Pipeline',
          '[WorkBench][Decoder] state=failed sequence=$sequence '
              'error=${_oneLine(error)}',
          isError: true,
        );
      }
    });
  }

  void _meterPcm(Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    for (var offset = 0; offset + 1 < pcm.length; offset += 2) {
      final sample = data.getInt16(offset, Endian.little);
      final magnitude = sample.abs();
      if (magnitude > _meterPeak) {
        _meterPeak = magnitude;
      }
      _meterSquareSum += sample * sample;
      _meterSamples++;
    }
    final now = DateTime.now();
    _meterStartedAt ??= now;
    if (now.difference(_meterStartedAt!) < const Duration(seconds: 1) ||
        _meterSamples == 0) {
      return;
    }
    final rms = sqrt(_meterSquareSum / _meterSamples);
    log(
      'PCM',
      '[WorkBench][PCM] rms=${rms.toStringAsFixed(1)} '
          'peak=$_meterPeak samples=$_meterSamples',
    );
    _meterSamples = 0;
    _meterSquareSum = 0;
    _meterPeak = 0;
    _meterStartedAt = now;
  }

  void _queueVadRecovery(Uint8List pcm) {
    final stable = Uint8List.fromList(pcm);
    _vadRecovery.addLast(stable);
    _vadRecoveryBytes += stable.length;
    while (_vadRecoveryBytes > _maximumVadRecoveryBytes &&
        _vadRecovery.isNotEmpty) {
      _vadRecoveryBytes -= _vadRecovery.removeFirst().length;
    }
  }

  void _replayVadRecovery() {
    final vad = _vad;
    if (vad == null || !vad.isReady || _vadRecovery.isEmpty) {
      return;
    }
    for (final pcm in _vadRecovery) {
      vad.acceptPcm(pcm);
    }
    log(
      'Pipeline',
      '[WorkBench][VAD] state=recovered '
          'pcm_bytes=$_vadRecoveryBytes',
    );
    _vadRecovery.clear();
    _vadRecoveryBytes = 0;
  }

  void _onSpeechSegment(String id, String wavPath) {
    unawaited(
      _exportSharedFiles(<String>[wavPath], reason: 'audio', segmentId: id),
    );
    _transcription?.transcribe(id, wavPath);
  }

  void _onTranscript(String id, String text, String transcriptPath) {
    lastTranscriptPath = transcriptPath;
    unawaited(
      _exportSharedFiles(
        <String>[transcriptPath],
        reason: 'transcript',
        segmentId: id,
      ),
    );
    completedTranscripts++;
    final displayed = _transcriptTurn.completeTurn(id, text);
    if (!displayed) {
      log(
        'Pipeline',
        '[WorkBench][TranscriptUI] state=suppressed segment=$id '
            'latest=${_transcriptTurn.currentSegmentId ?? 'none'}',
      );
    }
    startup = StartupSnapshot(
      phase: StartupPhase.ready,
      message: 'Local audio ready · $activeModelName · $activeProvider',
      provider: activeProvider,
    );
    onChanged();
  }

  Future<void> syncSharedAudioExport() async {
    final speechPath = _speechPath;
    if (speechPath == null || !_sharedAudioExportStore.hasSharedFolder) {
      return;
    }
    final directory = Directory(speechPath);
    if (!await directory.exists()) {
      return;
    }
    final paths = await directory
        .list()
        .where(
          (entity) =>
              entity is File &&
              (entity.path.endsWith('.wav') || entity.path.endsWith('.txt')),
        )
        .map((entity) => entity.path)
        .toList();
    await _exportSharedFiles(paths, reason: 'sync');
  }

  Future<void> _exportSharedFiles(
    Iterable<String> paths, {
    required String reason,
    String? segmentId,
  }) async {
    if (!_sharedAudioExportStore.hasSharedFolder) {
      return;
    }
    _sharedExportOperations++;
    sharedExportError = null;
    onChanged();
    try {
      final count = await _sharedAudioExportStore.exportFiles(paths);
      sharedExportedFiles += count;
      log(
        'Pipeline',
        '[WorkBench][SharedStorage] state=exported reason=$reason '
            'files=$count${segmentId == null ? '' : ' segment=$segmentId'}',
      );
    } catch (error) {
      sharedExportError =
          'Shared-folder export failed. Choose the save folder again.';
      log(
        'Pipeline',
        '[WorkBench][SharedStorage] state=failed reason=$reason '
            'error=${_oneLine(error)}',
        isError: true,
      );
    } finally {
      _sharedExportOperations--;
      onChanged();
    }
  }

  void _pipelineStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
  }

  void _vadStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
    if (message.contains('state=ready')) {
      activeVadProvider =
          RegExp(r'provider=(\S+)').firstMatch(message)?.group(1) ??
          activeVadProvider;
    }
    if (message.contains('state=speech_started')) {
      final segmentId = RegExp(
        r'\bsegment=(\S+)',
      ).firstMatch(message)?.group(1);
      if (segmentId != null) {
        _transcriptTurn.startTurn(segmentId);
        log(
          'Pipeline',
          '[WorkBench][TranscriptUI] state=cleared '
              'reason=speech_started segment=$segmentId',
        );
        onChanged();
      }
    }
    final ready = message.contains('state=ready');
    if (!ready && (message.contains('state=restarting') || isError)) {
      _vadWasReady = false;
      if (startup.isReady) {
        startup = StartupSnapshot(
          phase: StartupPhase.degraded,
          message: 'Audio safely recording · restarting voice detection…',
          provider: activeProvider,
          recoverable: true,
        );
        onChanged();
      }
    } else if (ready && !_vadWasReady) {
      _vadWasReady = true;
      _replayVadRecovery();
      if (startup.phase == StartupPhase.degraded) {
        startup = StartupSnapshot(
          phase: StartupPhase.ready,
          message: 'Voice detection recovered · audio remained safe',
          provider: activeProvider,
        );
        onChanged();
      }
    }
  }

  void _transcriptionStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
    if (!_initialStartupComplete) {
      if (message.contains('state=loading')) {
        final provider = RegExp(
          r'provider=(\S+)',
        ).firstMatch(message)?.group(1);
        _setStartup(
          StartupPhase.transcription,
          'Loading transcription${provider == null ? '' : ' · $provider'}…',
        );
      }
      return;
    }
    if (message.contains('state=restarting') ||
        message.contains('state=failed')) {
      startup = StartupSnapshot(
        phase: StartupPhase.degraded,
        message: 'Audio safely recording · restarting transcription…',
        provider: activeProvider,
        recoverable: true,
      );
      onChanged();
    } else if (message.contains('state=ready') &&
        message.contains('recovered=true')) {
      activeProvider =
          RegExp(r'provider=(\S+)').firstMatch(message)?.group(1) ??
          activeProvider;
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Transcription recovered · audio remained safe',
        provider: activeProvider,
      );
      onChanged();
    } else if (message.contains('state=processing')) {
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Transcribing speech locally…',
        provider: activeProvider,
      );
      onChanged();
    }
  }

  void _setStartup(StartupPhase phase, String message, {String? provider}) {
    startup = StartupSnapshot(
      phase: phase,
      message: message,
      provider: provider,
    );
    onChanged();
  }

  void handleWearableDisconnect({required bool expected}) {
    _transcriptTurn.endSession();
    _vad?.flush();
    log(
      'Pipeline',
      '[WorkBench][Bluetooth] state=disconnected expected=$expected '
          'capture=preserved transcription=available',
    );
    log(
      'Pipeline',
      '[WorkBench][TranscriptUI] state=cleared reason=disconnect',
    );
    if (startup.isReady) {
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: expected
            ? 'Devices disconnected · local models remain ready'
            : 'Connection lost · audio flushed safely · reconnecting…',
        provider: activeProvider,
      );
    }
    onChanged();
  }

  void handleWearableReconnect() {
    log(
      'Pipeline',
      '[WorkBench][Bluetooth] state=connected recovered=true '
          'capture=ready transcription=available',
    );
    if (startup.isReady) {
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Connection recovered · local audio ready',
        provider: activeProvider,
      );
      onChanged();
    }
  }

  Future<void> restartTranscriptionForTest() async {
    await _transcription?.restartForTest();
  }

  Future<void> restartVadForTest() async {
    await _vad?.restartForTest();
  }

  Future<void> selectTranscriptionModel(
    SpeechModelDefinition requestedModel,
  ) async {
    if (_disposed) {
      throw StateError('The local audio system is closed.');
    }
    if (_modelSwitching) {
      throw StateError('A transcription model is already loading.');
    }
    if (requestedModel.id == activeModelId &&
        _transcription != null &&
        startup.isReady) {
      return;
    }

    _modelSwitching = true;
    try {
      final speechPath = _speechPath;
      final providers = _inferenceProviders;
      final oldSupervisor = _transcription;
      final oldPaths = _transcriptionPaths;
      final oldModel = _selectedModel;
      if (speechPath == null ||
          providers == null ||
          oldSupervisor == null ||
          oldPaths == null) {
        await _resetAndInitialize(requestedModel);
        return;
      }

      _setStartup(
        StartupPhase.transcription,
        'Verifying ${requestedModel.displayName}…',
      );
      late final TranscriptionModelPaths requestedPaths;
      try {
        requestedPaths = await _modelStore.prepareTranscriptionModel(
          definition: requestedModel,
          onStatus: (message) {
            _setStartup(StartupPhase.transcription, message);
          },
        );
      } catch (error) {
        _setStartup(
          StartupPhase.ready,
          'Local audio ready · $activeModelName · $activeProvider',
          provider: activeProvider,
        );
        log(
          'Pipeline',
          '[WorkBench][Transcription] state=switch_failed '
              'model=${requestedModel.id} error=${_oneLine(error)} '
              'action=keep_current',
          isError: true,
        );
        throw StateError(
          'Could not prepare ${requestedModel.displayName}: '
          '${_oneLine(error)} '
          '$activeModelName remains active.',
        );
      }

      log(
        'Pipeline',
        '[WorkBench][Transcription] state=switching '
            'from=${oldModel.id} to=${requestedModel.id} '
            'capture=continuous vad=continuous',
      );
      _transcription = null;
      await oldSupervisor.dispose();

      final candidate = _newTranscriptionSupervisor(
        model: requestedPaths,
        speechPath: speechPath,
        providers: providers,
      );
      _transcription = candidate;
      try {
        final provider = await candidate.start();
        _transcriptionPaths = requestedPaths;
        _selectedModel = requestedModel;
        activeModelId = requestedModel.id;
        activeModelName = requestedModel.displayName;
        activeProvider = provider;
        _setStartup(
          StartupPhase.ready,
          'Local audio ready · $activeModelName · $activeProvider',
          provider: activeProvider,
        );
        log(
          'Pipeline',
          '[WorkBench][Transcription] state=switched '
              'model=${requestedModel.id} provider=$provider '
              'capture=continuous vad=continuous',
        );
      } catch (switchError) {
        await candidate.dispose();
        _transcription = null;
        log(
          'Pipeline',
          '[WorkBench][Transcription] state=switch_failed '
              'model=${requestedModel.id} error=${_oneLine(switchError)} '
              'action=restore_previous',
          isError: true,
        );
        try {
          final fallback = _newTranscriptionSupervisor(
            model: oldPaths,
            speechPath: speechPath,
            providers: providers,
          );
          _transcription = fallback;
          final provider = await fallback.start();
          _transcriptionPaths = oldPaths;
          _selectedModel = oldModel;
          activeModelId = oldModel.id;
          activeModelName = oldModel.displayName;
          activeProvider = provider;
          _setStartup(
            StartupPhase.ready,
            'Restored $activeModelName · $activeProvider',
            provider: activeProvider,
          );
          log(
            'Pipeline',
            '[WorkBench][Transcription] state=restored '
                'model=${oldModel.id} provider=$provider',
          );
        } catch (restoreError) {
          _setStartup(
            StartupPhase.failed,
            'Transcription models could not load: ${_oneLine(restoreError)}',
          );
          throw StateError(
            'Could not load ${requestedModel.displayName}, and restoring '
            '${oldModel.displayName} also failed: ${_oneLine(restoreError)}',
          );
        }
        throw StateError(
          'Could not load ${requestedModel.displayName}. '
          '${oldModel.displayName} was restored.',
        );
      }
    } finally {
      _modelSwitching = false;
      onChanged();
    }
  }

  TranscriptionSupervisor _newTranscriptionSupervisor({
    required TranscriptionModelPaths model,
    required String speechPath,
    required List<String> providers,
  }) {
    return TranscriptionSupervisor(
      model: model,
      speechPath: speechPath,
      providers: providers,
      onTranscript: _onTranscript,
      onStatus: _transcriptionStatus,
    );
  }

  Future<void> retryInitialize({
    SpeechModelDefinition? transcriptionModel,
  }) async {
    if (_disposed || startup.isBusy) {
      return;
    }
    await _resetAndInitialize(transcriptionModel ?? _selectedModel);
  }

  Future<void> _resetAndInitialize(
    SpeechModelDefinition transcriptionModel,
  ) async {
    _initialized = false;
    _initialStartupComplete = false;
    await _capture?.dispose();
    await _vad?.dispose();
    await _transcription?.dispose();
    await _decoder.dispose();
    _capture = null;
    _vad = null;
    _transcription = null;
    _transcriptionPaths = null;
    _speechPath = null;
    _inferenceProviders = null;
    activeModelId = null;
    activeModelName = null;
    activeProvider = null;
    activeVadProvider = null;
    _vadRecovery.clear();
    _vadRecoveryBytes = 0;
    _setStartup(StartupPhase.starting, 'Restarting local audio system…');
    await initialize(transcriptionModel: transcriptionModel);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _capture?.dispose();
    await _vad?.dispose();
    await _transcription?.dispose();
    await _decodeTail.catchError((Object _) {});
    await _decoder.dispose();
  }

  String _oneLine(Object? value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}
