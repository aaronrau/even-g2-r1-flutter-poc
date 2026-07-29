import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio/audio_pipeline_coordinator.dart';
import 'audio/conversation_analysis_service.dart';
import 'audio/shared_audio_export_store.dart';
import 'audio/speech_model.dart';
import 'audio/speech_model_preferences.dart';
import 'audio/transcript_correction_config.dart';
import 'audio/vad_worker.dart';
import 'audio/voice_memo_models.dart';
import 'audio/voice_memo_service.dart';
import 'background/app_runtime_coordinator.dart';
import 'background/background_service.dart';
import 'ble/ble_models.dart';
import 'ble/g2_connection.dart';
import 'ble/glasses_status_queue.dart';
import 'ble/r1_connection.dart';
import 'protocol/g2_protocol.dart';
import 'util/hex.dart';
import 'startup/startup_state.dart';
import 'websocket/voice_websocket_client.dart';
import 'websocket/voice_websocket_config.dart';
import 'websocket/websocket_message_store.dart';

final class WearableController extends ChangeNotifier
    with WidgetsBindingObserver {
  WearableController({
    FlutterReactiveBle? ble,
    SpeechModelPreferences speechModelPreferences =
        const SpeechModelPreferences(),
    SharedAudioExportStore? sharedAudioExportStore,
    WebSocketMessageStore? webSocketMessageStore,
    VoiceWebSocketConfigStore? voiceWebSocketConfigStore,
  }) : _ble = ble ?? FlutterReactiveBle(),
       _speechModelPreferences = speechModelPreferences,
       _sharedAudioExportStore =
           sharedAudioExportStore ?? SharedAudioExportStore(),
       _webSocketMessageStore =
           webSocketMessageStore ?? WebSocketMessageStore() {
    _sharedAudioExportStore.addListener(_sharedStorageChanged);
    _runtime = AppRuntimeCoordinator(log: addLog);
    _voiceWebSocket = VoiceWebSocketClient(
      configStore: voiceWebSocketConfigStore,
      onInboundMessage: _handleInboundWebSocketMessage,
    );
    _voiceWebSocket.addListener(_voiceWebSocketChanged);
    _conversationAnalysis = ConversationAnalysisService(
      log: addLog,
      onChanged: _safeNotify,
      sharedAudioExportStore: _sharedAudioExportStore,
    );
    _voiceMemo = VoiceMemoService(log: addLog, onChanged: _memoChanged);
    _audioPipeline = AudioPipelineCoordinator(
      log: addLog,
      onChanged: _safeNotify,
      onCaptureUnsafe: _handleUnsafeCapture,
      onQueuedTranscript: _handleQueuedTranscript,
      onFinalTranscript: _handleFinalTranscript,
      onFinalizedSpeechSegment: _conversationAnalysis.acceptFinalizedSegment,
      onVadSpeechEvent: _handleVadSpeechEvent,
      correctionTermsProvider: () => <String>[
        VoiceMemoService.wakePhrase,
        ..._voiceWebSocket.config.agentNames,
      ],
      sharedAudioExportStore: _sharedAudioExportStore,
    );
    g2 = G2Connection(
      ble: _ble,
      log: addLog,
      onChanged: _connectionChanged,
      onAudioChanged: _audioChanged,
      onLc3Audio: _audioPipeline.acceptLc3,
      onUnexpectedDisconnect: _unexpectedG2Disconnect,
      onGesture: _handleG2Gesture,
    );
    _glassesStatusQueue = GlassesStatusQueue(
      isConnected: () => g2.isConnected,
      showText: g2.sendText,
      clearText: g2.clearText,
      log: (message, {bool isError = false}) =>
          addLog('Glasses status', message, isError: isError),
    );
    r1 = R1Connection(ble: _ble, log: addLog, onChanged: _connectionChanged);
  }

  final FlutterReactiveBle _ble;
  final SpeechModelPreferences _speechModelPreferences;
  final SharedAudioExportStore _sharedAudioExportStore;
  final WebSocketMessageStore _webSocketMessageStore;
  late final AppRuntimeCoordinator _runtime;
  late final VoiceWebSocketClient _voiceWebSocket;
  late final ConversationAnalysisService _conversationAnalysis;
  late final VoiceMemoService _voiceMemo;
  late final AudioPipelineCoordinator _audioPipeline;
  late final G2Connection g2;
  late final GlassesStatusQueue _glassesStatusQueue;
  late final R1Connection r1;
  StreamSubscription<BleStatus>? _statusSubscription;
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  Timer? _scanTimer;
  Timer? _notifyTimer;
  Timer? _audioNotifyTimer;
  Timer? _backgroundNotifyTimer;
  Future<void> _memoDisplayTail = Future<void>.value();
  bool _disposed = false;
  bool _g2UnexpectedlyDisconnected = false;
  bool _linkingController = false;
  bool _sharedMessageViewActive = false;
  bool? _runtimeSessionActive;
  String? _lastControllerLinkKey;
  String? _announcedFinalizedMemoId;
  SpeechModelDefinition _selectedSpeechModel = defaultSpeechModel();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  static const Duration _audioUiFrameInterval = Duration(milliseconds: 33);
  static const int _maximumLogEntries = 30;
  static const int _memoryPressureLogEntries = _maximumLogEntries;
  static const int _maximumLogMessageCharacters = 2048;

  BleStatus bleStatus = BleStatus.unknown;
  bool scanning = false;
  String? rememberedG2Serial;
  String? rememberedR1Id;
  final Map<String, G2PairCandidate> _g2ByKey = <String, G2PairCandidate>{};
  final Map<String, DiscoveredDevice> _r1ById = <String, DiscoveredDevice>{};
  final Set<String> _loggedR1Advertisements = <String>{};
  final List<PooledLog> logs = <PooledLog>[];

  StartupSnapshot get startup => _audioPipeline.startup;
  bool get canConnect => _audioPipeline.canConnect;
  String? get audioFolder => _audioPipeline.audioFolder;
  SharedAudioFolder? get sharedAudioFolder => _sharedAudioExportStore.folder;
  bool get supportsSharedAudioFolder => _sharedAudioExportStore.isSupported;
  bool get isExportingSharedAudio => _audioPipeline.isExportingSharedAudio;
  String? get sharedAudioExportError => _audioPipeline.sharedExportError;
  int get sharedExportedFiles => _audioPipeline.sharedExportedFiles;
  List<SharedTranscript> get sharedTranscripts =>
      _sharedAudioExportStore.transcripts;
  List<SharedWebSocketMessage> get sharedWebSocketMessages =>
      _sharedAudioExportStore.messages;
  bool get isLoadingSharedMessages =>
      _sharedAudioExportStore.isLoadingTranscripts ||
      _sharedAudioExportStore.isLoadingMessages;
  String? get sharedMessageError =>
      _sharedAudioExportStore.messageLoadError ??
      _sharedAudioExportStore.transcriptLoadError;
  String? get lastTranscript => _audioPipeline.lastTranscript;
  int get completedTranscripts => _audioPipeline.completedTranscripts;
  String? get transcriptionProvider => _audioPipeline.activeProvider;
  String? get vadProvider => _audioPipeline.activeVadProvider;
  String? get correctionProvider => _audioPipeline.activeCorrectionProvider;
  String get correctionState => _audioPipeline.correctionState;
  int get pendingCorrections => _audioPipeline.pendingCorrections;
  int get completedCorrections => _audioPipeline.completedCorrections;
  TranscriptCorrectionConfig get correctionConfig =>
      _audioPipeline.correctionConfig;
  String? get correctionConfigValidationError =>
      _audioPipeline.correctionConfigValidationError;
  bool get hasWearableSession => _hasWearableSession;
  List<SpeechModelDefinition> get speechModels => availableSpeechModels;
  String get selectedSpeechModelId => _selectedSpeechModel.id;
  String get selectedSpeechModelName => _selectedSpeechModel.displayName;
  bool get isSwitchingSpeechModel => _audioPipeline.isSwitchingModel;
  VoiceWebSocketConfig get voiceWebSocketConfig => _voiceWebSocket.config;
  VoiceWebSocketStatus get voiceWebSocketStatus => _voiceWebSocket.status;
  String get voiceWebSocketStatusText => _voiceWebSocket.statusText;
  String? get voiceWebSocketValidationError => _voiceWebSocket.validationError;
  List<SharedConversationTurn> get conversations =>
      _sharedAudioExportStore.conversations;
  bool get isLoadingConversations =>
      _sharedAudioExportStore.isLoadingConversations;
  String? get conversationLoadError =>
      _sharedAudioExportStore.conversationLoadError;
  bool get conversationAnalysisEnabled => _conversationAnalysis.enabled;
  bool get conversationAnalysisStarting => _conversationAnalysis.isStarting;
  bool get conversationAnalysisReady => _conversationAnalysis.isReady;
  bool get conversationNeedsEnrollment => _conversationAnalysis.needsEnrollment;
  bool get conversationEnrollmentPending =>
      _conversationAnalysis.isEnrollmentPending;
  String get conversationAnalysisState => _conversationAnalysis.state;
  String? get conversationAnalysisError => _conversationAnalysis.error;
  int get knownSpeakerCount => _conversationAnalysis.knownSpeakerCount;
  int get pendingConversationCount => _conversationAnalysis.pendingCount;
  int get completedConversations =>
      _conversationAnalysis.completedConversations;
  List<VoiceMemoRecord> get voiceMemos => _voiceMemo.records;
  bool get voiceMemoActive => _voiceMemo.isActive;

  List<G2PairCandidate> get g2Candidates {
    final values = _g2ByKey.values.toList(growable: false);
    values.sort((left, right) {
      if (left.isComplete != right.isComplete) {
        return left.isComplete ? -1 : 1;
      }
      return left.serialNumber.compareTo(right.serialNumber);
    });
    return values;
  }

  List<DiscoveredDevice> get r1Candidates {
    final values = _r1ById.values.toList(growable: false);
    values.sort((left, right) => right.rssi.compareTo(left.rssi));
    return values;
  }

  List<PooledLog> get eventLogs => logs.toList(growable: false);

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    await _runtime.initialize();
    try {
      await _sharedAudioExportStore.initialize();
    } catch (error) {
      addLog(
        'Storage',
        '[WorkBench][SharedStorage] state=unavailable '
            'action=choose_folder_again error=$error',
        isError: true,
      );
    }
    try {
      await _webSocketMessageStore.initialize();
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=archive_unavailable '
            'action=check_app_storage',
        isError: true,
      );
    }
    try {
      await _voiceWebSocket.initialize();
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=unavailable '
            'action=check_app_storage',
        isError: true,
      );
    }
    try {
      await _voiceMemo.initialize();
    } on Object {
      addLog(
        'Memo',
        '[WorkBench][Memo] state=storage_unavailable '
            'capture=unaffected transcription=unaffected',
        isError: true,
      );
    }
    if (_sharedAudioExportStore.hasSharedFolder) {
      unawaited(_syncWebSocketMessages());
    }
    _selectedSpeechModel = await _speechModelPreferences.load();
    try {
      await _audioPipeline.initialize(transcriptionModel: _selectedSpeechModel);
    } catch (_) {
      // The pipeline publishes an actionable startup failure. Bluetooth stays
      // gated because connecting without durable capture would violate the
      // audio-safety contract.
    }
    unawaited(_conversationAnalysis.initialize());
    final preferences = await SharedPreferences.getInstance();
    rememberedG2Serial = preferences.getString('remembered_g2_serial');
    rememberedR1Id = preferences.getString('remembered_r1_id');
    await preferences.remove('r1_direct_input_mode');
    _statusSubscription = _ble.statusStream.listen((status) {
      bleStatus = status;
      addLog('BLE', 'Adapter: ${status.name}');
      _safeNotify();
    });
    if (_audioPipeline.canConnect) {
      addLog(
        'App',
        'Ready. R1 input uses the supported Tri-Sync path through G2.',
      );
    } else {
      addLog(
        'App',
        'Choose an installed transcription model in Tools, then retry.',
        isError: true,
      );
    }
  }

  Future<void> startScan({
    Duration duration = const Duration(seconds: 12),
  }) async {
    if (!canConnect) {
      throw StateError('Wait for the local audio system to become ready.');
    }
    if (scanning) {
      return;
    }
    await _requestPermissions();
    await stopScan();
    _g2ByKey.clear();
    _r1ById.clear();
    _loggedR1Advertisements.clear();
    scanning = true;
    _safeNotify();
    addLog('BLE', 'Low-latency scan started for ${duration.inSeconds}s');

    _scanSubscription = _ble
        .scanForDevices(
          withServices: const <Uuid>[],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: false,
        )
        .listen(
          _onDiscovered,
          onError: (Object error) {
            scanning = false;
            addLog('BLE scan', '$error', isError: true);
            _safeNotify();
          },
        );
    _scanTimer = Timer(duration, () {
      unawaited(stopScan());
    });
  }

  void _onDiscovered(DiscoveredDevice device) {
    final pair = G2PairCandidate.fromDevice(device);
    if (pair != null) {
      final existing = _g2ByKey[pair.key];
      _g2ByKey[pair.key] = (existing ?? pair).merge(device);
    } else if (isR1(device)) {
      _r1ById[device.id] = device;
      if (_loggedR1Advertisements.add(device.id)) {
        final serviceData = device.serviceData.entries
            .map(
              (entry) =>
                  '${entry.key}='
                  '${hexOf(entry.value, maxBytes: entry.value.length)}',
            )
            .join(', ');
        addLog(
          'R1 advertisement',
          '${device.name} (${device.id}) • RSSI ${device.rssi} dBm • '
              'connectable=${device.connectable.name} • '
              'services=${device.serviceUuids.isEmpty ? 'none' : device.serviceUuids.join(', ')} • '
              'manufacturer='
              '${device.manufacturerData.isEmpty ? 'none' : hexOf(device.manufacturerData, maxBytes: device.manufacturerData.length)} • '
              'serviceData=${serviceData.isEmpty ? 'none' : serviceData}',
        );
      }
    } else {
      return;
    }
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      _safeNotify();
    });
  }

  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (scanning) {
      scanning = false;
      addLog(
        'BLE',
        'Scan stopped: ${g2Candidates.length} G2 pair candidate(s), '
            '${r1Candidates.length} R1 ring(s)',
      );
      _safeNotify();
    }
  }

  Future<void> connectG2(G2PairCandidate pair) async {
    if (!canConnect) {
      throw StateError('Local audio safety checks are not ready.');
    }
    await stopScan();
    await _runtime.setWearableSessionActive(true);
    try {
      await g2.connect(pair);
      rememberedG2Serial = pair.serialNumber;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('remembered_g2_serial', pair.serialNumber);
      await _linkRingAndGlasses();
    } finally {
      await _syncBackgroundService();
    }
  }

  Future<void> connectR1(DiscoveredDevice device) async {
    await stopScan();
    await _runtime.setWearableSessionActive(true);
    try {
      await r1.connect(device, glassesMac: g2.rightMac);
      rememberedR1Id = device.id;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('remembered_r1_id', device.id);
      await _linkRingAndGlasses();
    } finally {
      await _syncBackgroundService();
    }
  }

  Future<void> disconnectG2() async {
    await g2.disconnect();
    _lastControllerLinkKey = null;
    _audioPipeline.handleWearableDisconnect(expected: true);
    _voiceMemo.handleWearableDisconnect();
    await _syncBackgroundService();
  }

  Future<void> disconnectR1() async {
    await r1.disconnect();
    _lastControllerLinkKey = null;
    await _syncBackgroundService();
  }

  Future<void> disconnectAll() async {
    await stopScan();
    await Future.wait(<Future<void>>[g2.disconnect(), r1.disconnect()]);
    _g2UnexpectedlyDisconnected = false;
    // A Tri-Sync handoff belongs to the current BLE session. Retaining this
    // deduplication key across a reset makes the next connection skip the
    // handoff and leaves Android directly attached to R1.
    _lastControllerLinkKey = null;
    _audioPipeline.handleWearableDisconnect(expected: true);
    _voiceMemo.handleWearableDisconnect();
    await _syncBackgroundService();
  }

  Future<void> restartTranscriptionForTest() =>
      _audioPipeline.restartTranscriptionForTest();

  Future<void> restartVadForTest() => _audioPipeline.restartVadForTest();

  Future<void> retryAudioPipeline() =>
      _audioPipeline.retryInitialize(transcriptionModel: _selectedSpeechModel);

  Future<void> selectSpeechModel(String modelId) async {
    final model = speechModelForId(modelId);
    if (model == null) {
      throw ArgumentError.value(modelId, 'modelId', 'Unknown speech model');
    }
    if (model.id == _selectedSpeechModel.id && startup.isReady) {
      return;
    }
    await _audioPipeline.selectTranscriptionModel(model);
    await _speechModelPreferences.save(model);
    _selectedSpeechModel = model;
    addLog(
      'Pipeline',
      '[WorkBench][Transcription] state=preference_saved model=${model.id}',
    );
    _safeNotify();
  }

  Future<void> saveCorrectionInstructions(String instructions) async {
    await _audioPipeline.saveCorrectionInstructions(instructions);
    addLog(
      'Pipeline',
      '[WorkBench][CorrectionConfig] state=saved applies=next_transcript',
    );
    _safeNotify();
  }

  Future<void> resetCorrectionInstructions() async {
    await _audioPipeline.resetCorrectionInstructions();
    addLog(
      'Pipeline',
      '[WorkBench][CorrectionConfig] state=reset applies=next_transcript',
    );
    _safeNotify();
  }

  Future<void> setCorrectionEnabled(bool enabled) async {
    await _audioPipeline.setCorrectionEnabled(enabled);
    addLog(
      'Pipeline',
      '[WorkBench][CorrectionConfig] state=${enabled ? 'enabled' : 'disabled'} '
          'applies=next_transcript',
    );
    _safeNotify();
  }

  Future<void> setConversationAnalysisEnabled(bool enabled) async {
    await _conversationAnalysis.setEnabled(enabled);
    _safeNotify();
  }

  void requestConversationEnrollment() {
    _conversationAnalysis.requestEnrollment();
    _safeNotify();
  }

  Future<void> clearConversationSpeakerProfiles() async {
    await _conversationAnalysis.clearSpeakerProfiles();
    _safeNotify();
  }

  Future<void> resetConversationPrimarySpeaker() async {
    await _conversationAnalysis.resetPrimarySpeakerProfile();
    _safeNotify();
  }

  Future<void> refreshConversations() =>
      _sharedAudioExportStore.refreshConversations();

  Future<void> restartConversationWorkerForTest() =>
      _conversationAnalysis.restartWorkerForTest();

  Future<void> saveVoiceWebSocketConfig(VoiceWebSocketConfig config) async {
    await _voiceWebSocket.saveConfig(config);
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] state=saved '
          'auth=${config.authHeader.serializedName} '
          'agents=${config.agentNames.length} '
          'legacy=${config.useLegacyMessageShape}',
    );
    _safeNotify();
  }

  Future<void> connectVoiceWebSocket() => _voiceWebSocket.connect();

  Future<void> disconnectVoiceWebSocket() => _voiceWebSocket.disconnect();

  Future<void> chooseSharedAudioFolder() async {
    final selected = await _sharedAudioExportStore.chooseFolder();
    if (selected == null) {
      return;
    }
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] state=selected access=persisted',
    );
    _safeNotify();
    await _audioPipeline.syncSharedCorrectionInstructions();
    await _audioPipeline.syncSharedAudioExport();
    await _syncWebSocketMessages();
  }

  Future<void> clearSharedAudioFolder() async {
    await _sharedAudioExportStore.clearFolder();
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] state=cleared fallback=app_private',
    );
    _safeNotify();
  }

  Future<void> refreshSharedMessages({bool reconcileShared = false}) async {
    Object? failure;
    try {
      await _sharedAudioExportStore.refreshMessages(
        reconcileShared: reconcileShared,
      );
    } on Object catch (error) {
      failure = error;
    }
    try {
      await _sharedAudioExportStore.refreshTranscriptions(
        reconcileShared: reconcileShared,
      );
    } on Object catch (error) {
      failure ??= error;
    }
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] state=list_ready '
          'messages=${sharedWebSocketMessages.length} '
          'transcriptions=${sharedTranscripts.length}',
    );
    if (failure != null) {
      throw StateError('Could not refresh the shared message history.');
    }
  }

  void setSharedMessageViewActive(bool active) {
    _sharedMessageViewActive = active;
    _audioPipeline.setSharedTranscriptRefreshEnabled(active);
  }

  Future<void> toggleTranscriptAudio(SharedTranscript transcript) async {
    final wasPlaying = isPlayingTranscript(transcript);
    await _sharedAudioExportStore.toggleAudio(transcript);
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] '
          'state=${wasPlaying ? 'playback_stopped' : 'playback_started'} '
          'source=shared_folder',
    );
  }

  bool isPlayingTranscript(SharedTranscript transcript) =>
      transcript.audioFileName != null &&
      transcript.audioFileName == _sharedAudioExportStore.playingAudioFileName;

  Future<void> linkRingAndGlasses() async {
    _lastControllerLinkKey = null;
    await _linkRingAndGlasses();
  }

  Future<void> _linkRingAndGlasses() async {
    if (_linkingController || !g2.isConnected || !r1.isConnected) {
      return;
    }
    // The production Even app gives the R1 the right lens address. The ring
    // forms its controller link with that lens and G2 then forwards gestures
    // through EvenHub.
    final glassesMac = g2.rightMac;
    final ringMac = r1.deviceId;
    if (glassesMac == null) {
      addLog(
        'Tri-Sync',
        'The scanned G2 advertisement did not contain a right-lens MAC.',
        isError: true,
      );
      return;
    }
    if (ringMac == null ||
        !RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(ringMac)) {
      addLog(
        'Tri-Sync',
        'R1 hardware MAC unavailable from BLE id "$ringMac"; '
            'automatic linking currently requires Android.',
        isError: true,
      );
      return;
    }
    final key = '$glassesMac/$ringMac';
    if (_lastControllerLinkKey == key) {
      return;
    }
    _linkingController = true;
    try {
      addLog('Tri-Sync', 'Linking R1 $ringMac to G2 right lens $glassesMac');
      await r1.startGlassesHandoff(glassesMac);
      await Future<void>.delayed(const Duration(seconds: 1));
      await g2.connectRing(ringMac, ringName: r1.deviceName ?? '');
      _lastControllerLinkKey = key;
      addLog(
        'Tri-Sync',
        'R1 handoff was attempted and the G2 ring-connect command was sent. '
            'Waiting for a source=2 R1 event as the definitive link signal.',
      );
      // In Tri-Sync the phone connection is only a setup/diagnostic link.
      // Keeping it open can prevent the ring from completing or maintaining
      // its controller role with the right lens.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await r1.disconnect();
      addLog(
        'Tri-Sync',
        'Released the temporary phone → R1 GATT link. The R1 now belongs to '
            'the G2 controller path; its events are observed through G2.',
      );
    } catch (error) {
      addLog('Tri-Sync', 'Pairing failed: $error', isError: true);
      rethrow;
    } finally {
      _linkingController = false;
      _safeNotify();
    }
  }

  Future<void> _syncBackgroundService() async {
    final active = _hasWearableSession;
    _runtimeSessionActive = active;
    await _runtime.setWearableSessionActive(active);
    _safeNotify();
  }

  bool get _hasWearableSession =>
      g2.state != LinkState.disconnected || r1.state != LinkState.disconnected;

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.notification,
      ].request();
      final denied = statuses.entries
          .where(
            (entry) =>
                entry.key != Permission.notification && !entry.value.isGranted,
          )
          .map((entry) => entry.key.toString())
          .toList(growable: false);
      if (denied.isNotEmpty) {
        addLog(
          'Permissions',
          'Bluetooth permission not granted: ${denied.join(', ')}',
          isError: true,
        );
      }
      // Android 11 and older use location permission for BLE scans. Never ask
      // for it on Android 12+, where Nearby Devices is the correct permission.
      final sdkInt = await BackgroundConnectionService.androidSdkInt();
      if (sdkInt != null && sdkInt <= 30) {
        await Permission.locationWhenInUse.request();
      }
    } else if (Platform.isIOS) {
      await Permission.bluetooth.request();
    }
  }

  void addLog(String source, String message, {bool isError = false}) {
    debugPrint('[Even G2/R1][$source]${isError ? '[ERROR]' : ''} $message');
    // Audio is a continuous stream, not an event history. Keep only its
    // latest summary so it cannot bury connection and gesture events.
    if (source == 'Audio') {
      logs.removeWhere((entry) => entry.source == source);
    }
    logs.insert(
      0,
      PooledLog(
        timestamp: DateTime.now(),
        source: source,
        message: message.length <= _maximumLogMessageCharacters
            ? message
            : '${message.substring(0, _maximumLogMessageCharacters)}…',
        isError: isError,
      ),
    );
    if (logs.length > _maximumLogEntries) {
      logs.removeRange(_maximumLogEntries, logs.length);
    }
    _safeNotify();
  }

  void clearLogs() {
    logs.clear();
    _safeNotify();
  }

  void _connectionChanged() {
    if (_g2UnexpectedlyDisconnected && g2.isConnected) {
      _g2UnexpectedlyDisconnected = false;
      _audioPipeline.handleWearableReconnect();
    }
    _safeNotify();
    _glassesStatusQueue.connectionChanged();
    _queueMemoDisplaySync();
    final active = _hasWearableSession;
    if (_runtimeSessionActive != active) {
      _runtimeSessionActive = active;
      unawaited(_runtime.setWearableSessionActive(active));
    }
  }

  void _sharedStorageChanged() {
    _safeNotify();
  }

  void _voiceWebSocketChanged() {
    _safeNotify();
  }

  void _memoChanged() {
    if (_voiceMemo.isActive) {
      _glassesStatusQueue.setPaused(true);
    }
    _safeNotify();
    _queueMemoDisplaySync();
  }

  void _queueMemoDisplaySync() {
    final operation = _memoDisplayTail.then((_) => _syncMemoDisplay());
    _memoDisplayTail = operation.then<void>(
      (_) {},
      onError: (Object error) {
        addLog(
          'Memo',
          '[WorkBench][MemoDisplay] state=failed '
              'error=${_oneLine(error)}',
          isError: true,
        );
      },
    );
  }

  Future<void> _syncMemoDisplay() async {
    if (_disposed) {
      return;
    }
    final active = _voiceMemo.activeMemo;
    if (active != null) {
      _glassesStatusQueue.setPaused(true);
      if (g2.isConnected) {
        await g2.showMemo(
          note: _voiceMemo.displayText,
          status: active.status.label,
        );
      }
      return;
    }
    if (g2.isConnected && g2.isMemoDisplayActive) {
      await g2.exitMemo();
    }
    _glassesStatusQueue.setPaused(false);
    final finalizedId = _voiceMemo.lastFinalizedId;
    if (finalizedId != null && finalizedId != _announcedFinalizedMemoId) {
      _announcedFinalizedMemoId = finalizedId;
      await _glassesStatusQueue.queueTransient(
        prefix: 'Memo',
        message: 'Saved',
      );
    }
  }

  void _handleVadSpeechEvent(VadSpeechEvent event) {
    switch (event.type) {
      case VadSpeechEventType.started:
        _voiceMemo.speechStarted(event.segmentId);
      case VadSpeechEventType.ended:
        _voiceMemo.speechEnded(event.segmentId);
    }
  }

  bool _handleG2Gesture(G2GestureEvent event) {
    if (event.type != 3 || !_voiceMemo.isActive) {
      return false;
    }
    _audioPipeline.flushCurrentSpeech();
    _voiceMemo.requestFinalize(reason: 'double_tap');
    return true;
  }

  Future<void> _handleFinalTranscript(
    String segmentId,
    String transcript,
  ) async {
    if (await _voiceMemo.acceptFinalTranscript(segmentId, transcript)) {
      addLog(
        'Memo',
        '[WorkBench][Memo] state=transcript_consumed stage=final '
            'websocket=skipped',
      );
      return;
    }
    final route = _voiceWebSocket.routeForTranscript(transcript);
    if (route == null) {
      await _glassesStatusQueue.completeTranscript(
        segmentId: segmentId,
        transcript: transcript,
        outcome: GlassesTranscriptOutcome.saved,
      );
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=saved routed=false',
      );
      return;
    }
    final sent = await _voiceWebSocket.sendAgentMessage(
      agent: route.agent,
      message: route.message,
    );
    if (sent) {
      await _archiveWebSocketMessage(
        direction: WebSocketMessageDirection.sent,
        message: '${route.agent}: ${route.message}',
        failureState: 'sent_save_failed',
      );
    }
    await _glassesStatusQueue.completeTranscript(
      segmentId: segmentId,
      transcript: transcript,
      outcome: sent
          ? GlassesTranscriptOutcome.sent
          : GlassesTranscriptOutcome.saved,
    );
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] '
          'state=${sent ? 'sent' : 'saved'} routed=true',
    );
  }

  Future<void> _handleQueuedTranscript(
    String segmentId,
    String transcript,
  ) async {
    if (_voiceMemo.acceptRawTranscript(segmentId, transcript)) {
      addLog(
        'Memo',
        '[WorkBench][Memo] state=transcript_consumed stage=raw '
            'websocket=skipped',
      );
      return;
    }
    await _glassesStatusQueue.queueTranscript(
      segmentId: segmentId,
      transcript: transcript,
    );
  }

  Future<void> _handleInboundWebSocketMessage(String message) async {
    Object? persistenceError;
    try {
      final saved = await _webSocketMessageStore.save(
        direction: WebSocketMessageDirection.received,
        message: message,
      );
      try {
        final exported = await _sharedAudioExportStore.exportFiles(<String>[
          saved.path,
        ]);
        addLog(
          'WebSocket',
          '[WorkBench][VoiceWebSocket] state=received_saved '
              'shared=${exported > 0}',
        );
        if (exported > 0 && _sharedMessageViewActive) {
          unawaited(_refreshSharedWebSocketMessages());
        }
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][VoiceWebSocket] state=received_export_failed '
              'fallback=app_private',
          isError: true,
        );
      }
    } on Object catch (error) {
      persistenceError = error;
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=received_save_failed '
            'action=check_app_storage',
        isError: true,
      );
    }
    await _glassesStatusQueue.queueTransient(
      prefix: 'Received',
      message: message,
    );
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] state=received '
          'characters=${message.length}',
    );
    if (persistenceError != null) {
      throw StateError('Inbound message persistence failed.');
    }
  }

  Future<void> _archiveWebSocketMessage({
    required WebSocketMessageDirection direction,
    required String message,
    required String failureState,
  }) async {
    try {
      final saved = await _webSocketMessageStore.save(
        direction: direction,
        message: message,
      );
      try {
        final exported = await _sharedAudioExportStore.exportFiles(<String>[
          saved.path,
        ]);
        if (exported > 0 && _sharedMessageViewActive) {
          unawaited(_refreshSharedWebSocketMessages());
        }
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][VoiceWebSocket] state=message_export_failed '
              'fallback=app_private',
          isError: true,
        );
      }
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=$failureState '
            'action=check_app_storage',
        isError: true,
      );
    }
  }

  Future<void> _syncWebSocketMessages() async {
    if (!_sharedAudioExportStore.hasSharedFolder) {
      return;
    }
    try {
      final paths = await _webSocketMessageStore.savedPaths();
      if (paths.isEmpty) {
        return;
      }
      final exported = await _sharedAudioExportStore.exportFiles(paths);
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=message_sync '
            'files=$exported',
      );
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=message_sync_failed '
            'action=choose_folder_again',
        isError: true,
      );
    }
  }

  Future<void> _refreshSharedWebSocketMessages() async {
    try {
      await _sharedAudioExportStore.refreshMessages();
    } on Object {
      // The Messages view exposes the retained load error and a manual retry.
    }
  }

  void _unexpectedG2Disconnect(String side) {
    if (_g2UnexpectedlyDisconnected || _disposed) {
      return;
    }
    _g2UnexpectedlyDisconnected = true;
    _lastControllerLinkKey = null;
    addLog(
      'Pipeline',
      '[WorkBench][Bluetooth] state=disconnected expected=false side=$side',
      isError: true,
    );
    _audioPipeline.handleWearableDisconnect(expected: false);
    _voiceMemo.handleWearableDisconnect();
  }

  void _handleUnsafeCapture() {
    if (_disposed) {
      return;
    }
    addLog(
      'Pipeline',
      '[WorkBench][Capture] state=dropped action=disconnect',
      isError: true,
    );
    unawaited(disconnectAll());
  }

  void _audioChanged() {
    if (_disposed) {
      return;
    }
    if (_lifecycleState != AppLifecycleState.resumed) {
      _safeNotify();
      return;
    }
    if (_audioNotifyTimer != null) {
      return;
    }
    // G2 delivers about 100 LC3 frames per second. Keep processing every
    // frame, but repaint the Flutter UI at a smooth 30 FPS so BLE callbacks
    // and latency-sensitive gesture writes are not competing with 100 full
    // home-page rebuilds every second.
    _audioNotifyTimer = Timer(_audioUiFrameInterval, () {
      _audioNotifyTimer = null;
      _safeNotify();
    });
  }

  void _safeNotify() {
    if (_disposed) {
      return;
    }
    if (_lifecycleState == AppLifecycleState.resumed) {
      notifyListeners();
      return;
    }
    // BLE and audio stay fully active in the background. Only coalesce
    // non-visible Flutter UI notifications so they cannot build avoidable
    // rendering/state pressure while another app is in front.
    _backgroundNotifyTimer ??= Timer(const Duration(seconds: 1), () {
      _backgroundNotifyTimer = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  static String _oneLine(Object value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    addLog('Lifecycle', state.name);
    if (state != AppLifecycleState.resumed) {
      _audioNotifyTimer?.cancel();
      _audioNotifyTimer = null;
    }
    if (state == AppLifecycleState.resumed) {
      _backgroundNotifyTimer?.cancel();
      _backgroundNotifyTimer = null;
      unawaited(_conversationAnalysis.resumeAfterMemoryPressure());
      _safeNotify();
    }
    unawaited(
      _runtime.handleLifecycleState(
        state,
        wearableSessionActive: _hasWearableSession,
      ),
    );
  }

  @override
  void didHaveMemoryPressure() {
    _backgroundNotifyTimer?.cancel();
    _backgroundNotifyTimer = null;
    if (logs.length > _memoryPressureLogEntries) {
      logs.removeRange(_memoryPressureLogEntries, logs.length);
    }
    if (!scanning) {
      _g2ByKey.clear();
      _r1ById.clear();
      _loggedR1Advertisements.clear();
    }
    addLog(
      'Runtime',
      'Released nonessential diagnostic history after memory pressure',
    );
    unawaited(_audioPipeline.handleMemoryPressure());
    unawaited(_conversationAnalysis.handleMemoryPressure());
    unawaited(_voiceMemo.handleMemoryPressure());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _sharedAudioExportStore.removeListener(_sharedStorageChanged);
    _voiceWebSocket.removeListener(_voiceWebSocketChanged);
    _glassesStatusQueue.dispose();
    _sharedAudioExportStore.dispose();
    _scanTimer?.cancel();
    _notifyTimer?.cancel();
    _audioNotifyTimer?.cancel();
    _backgroundNotifyTimer?.cancel();
    unawaited(_scanSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(g2.dispose());
    unawaited(r1.dispose());
    unawaited(_conversationAnalysis.dispose());
    unawaited(_voiceMemo.dispose());
    unawaited(_audioPipeline.dispose());
    unawaited(_voiceWebSocket.close());
    unawaited(_runtime.dispose());
    super.dispose();
  }
}
