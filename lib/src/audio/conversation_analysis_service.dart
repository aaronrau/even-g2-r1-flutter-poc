import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'conversation_analysis_preferences.dart';
import 'conversation_analysis_worker.dart';
import 'conversation_model_store.dart';
import 'conversation_models.dart';
import 'conversation_record_store.dart';
import 'model_asset_store.dart';
import 'shared_audio_export_store.dart';
import 'speech_model.dart';

typedef ConversationServiceLog =
    void Function(String source, String message, {bool isError});

/// Optional, supervised analysis downstream of the already durable speech WAV.
///
/// No live LC3 or PCM buffer is copied. The primary capture/VAD/STT path closes
/// the WAV first, then offers only its path to this service. This service owns a
/// separate isolate and recognizer, and none of its futures are awaited by the
/// primary transcription or routing path.
final class ConversationAnalysisService {
  ConversationAnalysisService({
    required this.log,
    required this.onChanged,
    required SharedAudioExportStore sharedAudioExportStore,
    ConversationAnalysisPreferences preferences =
        const ConversationAnalysisPreferences(),
    ConversationRecordStore? recordStore,
    ConversationModelStore? modelStore,
    ModelAssetStore? speechModelStore,
  }) : _sharedAudioExportStore = sharedAudioExportStore,
       _preferences = preferences,
       _recordStore = recordStore ?? ConversationRecordStore(),
       _modelStore = modelStore ?? ConversationModelStore(),
       _speechModelStore = speechModelStore ?? ModelAssetStore();

  static const int _maximumPendingJobs = 32;

  final ConversationServiceLog log;
  final VoidCallback onChanged;
  final SharedAudioExportStore _sharedAudioExportStore;
  final ConversationAnalysisPreferences _preferences;
  final ConversationRecordStore _recordStore;
  final ConversationModelStore _modelStore;
  final ModelAssetStore _speechModelStore;
  final Queue<ConversationPendingJob> _jobs = Queue<ConversationPendingJob>();

  ConversationAnalysisSupervisor? _supervisor;
  List<SpeakerProfile> _profiles = const <SpeakerProfile>[];
  bool _initialized = false;
  bool _disposed = false;
  bool _starting = false;
  bool _jobActive = false;
  bool _enrollmentRequested = false;

  bool enabled = false;
  String state = 'disabled';
  String? error;
  int completedConversations = 0;

  bool get isStarting => _starting;
  bool get isReady => _supervisor?.isReady ?? false;
  bool get needsEnrollment =>
      enabled && !_profiles.any((profile) => profile.isPrimary);
  bool get isEnrollmentPending =>
      _enrollmentRequested ||
      (_jobs.isNotEmpty && _jobs.first.enrollment && _jobActive);
  int get knownSpeakerCount => _profiles.length;
  int get pendingCount => _jobs.length;

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    try {
      await _recordStore.initialize();
      _profiles = await _recordStore.loadProfiles();
      _jobs.addAll(await _recordStore.loadPendingJobs());
      enabled = await _preferences.loadEnabled();
      if (!enabled) {
        state = 'disabled';
        onChanged();
        return;
      }
      await _start();
    } catch (caught) {
      _fail(caught, stateName: 'unavailable');
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed) {
      return;
    }
    enabled = value;
    error = null;
    await _preferences.saveEnabled(value);
    if (!value) {
      state = 'disabled';
      _enrollmentRequested = false;
      _jobActive = false;
      _jobs.clear();
      await _persistJobs();
      final supervisor = _supervisor;
      _supervisor = null;
      await supervisor?.dispose();
      log(
        'Conversation',
        '[WorkBench][Conversation] state=disabled '
            'capture=unaffected transcription=unaffected',
      );
      onChanged();
      return;
    }
    await _start();
  }

  void requestEnrollment() {
    if (!enabled || _disposed) {
      return;
    }
    _enrollmentRequested = true;
    state = 'waiting_for_enrollment_speech';
    error = null;
    log(
      'Conversation',
      '[WorkBench][Conversation] state=enrollment_waiting '
          'prompt=speak_once',
    );
    onChanged();
  }

  Future<void> clearSpeakerProfiles() async {
    _profiles = const <SpeakerProfile>[];
    _enrollmentRequested = enabled;
    await _recordStore.clearProfiles();
    state = enabled ? 'waiting_for_enrollment_speech' : 'disabled';
    error = null;
    log(
      'Conversation',
      '[WorkBench][Conversation] state=profiles_cleared '
          'conversations_retained=true',
    );
    onChanged();
  }

  Future<void> resetPrimarySpeakerProfile() async {
    if (_disposed) {
      return;
    }
    if (_jobActive || _jobs.isNotEmpty) {
      throw StateError(
        'Wait for pending conversation analysis before resetting You.',
      );
    }
    _profiles = retainNonPrimarySpeakerProfiles(_profiles);
    _enrollmentRequested = enabled;
    state = enabled ? 'waiting_for_enrollment_speech' : 'disabled';
    error = null;
    onChanged();
    try {
      await _recordStore.saveProfiles(_profiles);
      log(
        'Conversation',
        '[WorkBench][Conversation] state=primary_profile_reset '
            'other_speakers_retained=${_profiles.length} '
            'conversations_retained=true',
      );
    } catch (caught) {
      _fail(caught, stateName: 'profile_storage_failed');
      rethrow;
    } finally {
      onChanged();
    }
  }

  /// Called after VAD has atomically finalized the speech WAV.
  ///
  /// This method deliberately returns void so the primary audio pipeline
  /// cannot await conversation analysis.
  void acceptFinalizedSegment(String segmentId, String wavPath) {
    if (!enabled || _disposed || segmentId.isEmpty || wavPath.isEmpty) {
      return;
    }
    final enrollment = _enrollmentRequested || needsEnrollment;
    _enrollmentRequested = false;
    if (_jobs.length >= _maximumPendingJobs) {
      final dropped = _jobs.removeFirst();
      log(
        'Conversation',
        '[WorkBench][Conversation] state=queue_trimmed '
            'segment=${dropped.segmentId} maximum=$_maximumPendingJobs '
            'capture=unaffected transcription=unaffected',
        isError: true,
      );
    }
    _jobs.addLast(
      ConversationPendingJob(
        segmentId: segmentId,
        wavPath: wavPath,
        enrollment: enrollment,
        queuedAt: DateTime.now().toUtc(),
      ),
    );
    state = enrollment ? 'enrolling' : 'queued';
    unawaited(_persistJobs());
    _dispatch();
    onChanged();
  }

  Future<void> _start() async {
    if (_starting || _disposed || !enabled || isReady) {
      return;
    }
    _starting = true;
    state = 'starting';
    error = null;
    onChanged();
    try {
      _status('verifying speaker models');
      final models = await _modelStore.prepare();
      final transcription = await _speechModelStore.prepareTranscriptionModel(
        definition: parakeet110mModel,
        onStatus: (message) => _status(message),
      );
      if (_disposed || !enabled) {
        return;
      }
      final supervisor = ConversationAnalysisSupervisor(
        models: models,
        transcription: transcription,
        onResult: _onResult,
        onFailure: _onFailure,
        onStatus: (message, {bool isError = false}) =>
            log('Conversation', message, isError: isError),
      );
      _supervisor = supervisor;
      await supervisor.start();
      state = needsEnrollment ? 'waiting_for_enrollment_speech' : 'ready';
      if (needsEnrollment) {
        _enrollmentRequested = true;
      }
      log(
        'Conversation',
        '[WorkBench][Conversation] state=$state provider=cpu '
            'independent_stt=${parakeet110mModel.id} '
            'capture=unaffected transcription=unaffected',
      );
      _dispatch();
    } catch (caught) {
      await _supervisor?.dispose();
      _supervisor = null;
      _fail(caught, stateName: 'unavailable');
    } finally {
      _starting = false;
      onChanged();
    }
  }

  void _dispatch() {
    final supervisor = _supervisor;
    if (_jobActive ||
        _jobs.isEmpty ||
        supervisor == null ||
        !supervisor.isReady ||
        _disposed) {
      return;
    }
    final job = _jobs.first;
    if (!File(job.wavPath).existsSync()) {
      _jobs.removeFirst();
      unawaited(_persistJobs());
      _dispatch();
      return;
    }
    _jobActive = true;
    state = job.enrollment ? 'enrolling' : 'analyzing';
    supervisor.analyze(
      segmentId: job.segmentId,
      wavPath: job.wavPath,
      profiles: _profiles,
      enrollment: job.enrollment,
    );
    onChanged();
  }

  void _onResult(ConversationAnalysisResult result) {
    unawaited(_retainResult(result));
  }

  Future<void> _retainResult(ConversationAnalysisResult result) async {
    _removeJob(result.record.id);
    _jobActive = false;
    await _persistJobs();
    try {
      _profiles = List<SpeakerProfile>.unmodifiable(result.profiles);
      await _recordStore.saveProfiles(_profiles);
      if (!result.enrollment) {
        final retained = await _recordStore.retainRecord(result.record);
        await _sharedAudioExportStore.indexConversation(retained);
        await _sharedAudioExportStore.exportFiles(<String>[retained.textPath]);
        completedConversations++;
      }
      state = 'ready';
      error = null;
    } catch (caught) {
      _fail(caught, stateName: 'storage_failed');
    } finally {
      _dispatch();
      onChanged();
    }
  }

  void _onFailure(String segmentId, Object caught) {
    _removeJob(segmentId);
    _jobActive = false;
    error = _oneLine(caught);
    state = 'analysis_failed';
    if (!_profiles.any((profile) => profile.isPrimary)) {
      _enrollmentRequested = true;
    }
    unawaited(_persistJobs());
    _dispatch();
    onChanged();
  }

  void _removeJob(String segmentId) {
    if (_jobs.isNotEmpty && _jobs.first.segmentId == segmentId) {
      _jobs.removeFirst();
    } else {
      _jobs.removeWhere((job) => job.segmentId == segmentId);
    }
  }

  Future<void> _persistJobs() async {
    try {
      await _recordStore.savePendingJobs(_jobs);
    } on Object {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=queue_persistence_failed '
            'capture=unaffected transcription=unaffected',
        isError: true,
      );
    }
  }

  void _status(String message) {
    log('Conversation', '[WorkBench][Conversation] state=model $message');
  }

  void _fail(Object caught, {required String stateName}) {
    state = stateName;
    error = _oneLine(caught);
    log(
      'Conversation',
      '[WorkBench][Conversation] state=$stateName '
          'capture=unaffected transcription=unaffected '
          'error=${_oneLine(caught)}',
      isError: true,
    );
    onChanged();
  }

  Future<void> restartWorkerForTest() async {
    await _supervisor?.restartForTest();
  }

  Future<void> handleMemoryPressure() async {
    if (!enabled || _disposed) {
      return;
    }
    final supervisor = _supervisor;
    _supervisor = null;
    _jobActive = false;
    await supervisor?.dispose();
    state = 'paused_for_memory';
    log(
      'Conversation',
      '[WorkBench][Conversation] state=paused_for_memory '
          'capture=unaffected transcription=unaffected',
    );
    onChanged();
  }

  Future<void> resumeAfterMemoryPressure() async {
    if (enabled && _supervisor == null) {
      await _start();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _persistJobs();
    await _supervisor?.dispose();
    _supervisor = null;
  }
}

String _oneLine(Object value) =>
    '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
