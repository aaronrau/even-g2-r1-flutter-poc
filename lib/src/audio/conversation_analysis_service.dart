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
    DateTime Function() clock = DateTime.now,
  }) : _sharedAudioExportStore = sharedAudioExportStore,
       _preferences = preferences,
       _recordStore = recordStore ?? ConversationRecordStore(),
       _modelStore = modelStore ?? ConversationModelStore(),
       _speechModelStore = speechModelStore ?? ModelAssetStore(),
       _clock = clock;

  static const int _maximumPendingJobs = 32;

  final ConversationServiceLog log;
  final VoidCallback onChanged;
  final SharedAudioExportStore _sharedAudioExportStore;
  final ConversationAnalysisPreferences _preferences;
  final ConversationRecordStore _recordStore;
  final ConversationModelStore _modelStore;
  final ModelAssetStore _speechModelStore;
  final DateTime Function() _clock;
  final Queue<ConversationPendingJob> _jobs = Queue<ConversationPendingJob>();

  ConversationAnalysisSupervisor? _supervisor;
  List<SpeakerProfile> _profiles = const <SpeakerProfile>[];
  bool _initialized = false;
  bool _disposed = false;
  bool _starting = false;
  bool _jobActive = false;
  bool _activeJobEnrollment = false;
  bool _enrollmentRequested = false;
  int? _minimumEnrollmentSegmentMicros;
  Future<void>? _memoryPressureRelease;

  bool enabled = false;
  String state = 'disabled';
  String? error;
  int completedConversations = 0;

  bool get isStarting => _starting;
  bool get isReady => _supervisor?.isReady ?? false;
  SpeakerProfile? get _primaryProfile {
    for (final profile in _profiles) {
      if (profile.isPrimary) {
        return profile;
      }
    }
    return null;
  }

  bool get needsEnrollment =>
      enabled &&
      (_primaryProfile == null || _primaryProfile!.enrollmentInProgress);
  bool get isEnrollmentPending =>
      _enrollmentRequested ||
      _activeJobEnrollment ||
      _jobs.any((job) => job.enrollment);
  int get acceptedEnrollmentSamples =>
      _primaryProfile?.acceptedEnrollmentSamples ?? 0;
  int get requiredEnrollmentSamples => minimumPrimarySpeakerEnrollmentSamples;
  int get knownSpeakerCount =>
      _profiles.where((profile) => profile.calibrationComplete).length;
  int get pendingCount => _jobs.length + (_jobActive && _jobs.isEmpty ? 1 : 0);

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    try {
      await _recordStore.initialize();
      final storedProfiles = await _recordStore.loadProfiles();
      _profiles = retainBoundedSpeakerProfiles(storedProfiles);
      if (storedProfiles.length != _profiles.length) {
        await _recordStore.saveProfiles(_profiles);
        log(
          'Conversation',
          '[WorkBench][Conversation] state=profiles_compacted '
              'before=${storedProfiles.length} after=${_profiles.length} '
              'maximum_other=$maximumNonPrimarySpeakerProfiles',
        );
      }
      _jobs.addAll(await _recordStore.loadPendingJobs());
      enabled = await _preferences.loadEnabled();
      if (!enabled) {
        state = 'disabled';
        onChanged();
        return;
      }
      if (needsEnrollment) {
        _enrollmentRequested = true;
        _minimumEnrollmentSegmentMicros = _nowMicros();
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
      _minimumEnrollmentSegmentMicros = null;
      _jobActive = false;
      _activeJobEnrollment = false;
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
    if (needsEnrollment) {
      _enrollmentRequested = true;
      _minimumEnrollmentSegmentMicros = _nowMicros();
    }
    await _start();
  }

  void requestEnrollment() {
    if (!enabled || _disposed) {
      return;
    }
    _enrollmentRequested = true;
    _minimumEnrollmentSegmentMicros = _nowMicros();
    state = 'waiting_for_enrollment_speech';
    error = null;
    log(
      'Conversation',
      '[WorkBench][Conversation] state=enrollment_waiting '
          'accepted=$acceptedEnrollmentSamples '
          'required=$requiredEnrollmentSamples',
    );
    onChanged();
  }

  Future<void> clearSpeakerProfiles() async {
    if (_disposed) {
      return;
    }
    if (_jobActive || _jobs.isNotEmpty) {
      throw StateError(
        'Wait for pending conversation analysis before clearing speakers.',
      );
    }
    _profiles = const <SpeakerProfile>[];
    _enrollmentRequested = enabled;
    _minimumEnrollmentSegmentMicros = enabled ? _nowMicros() : null;
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
    _profiles = retainBoundedSpeakerProfiles(
      retainNonPrimarySpeakerProfiles(_profiles),
    );
    _enrollmentRequested = enabled;
    _minimumEnrollmentSegmentMicros = enabled ? _nowMicros() : null;
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
    final minimumEnrollmentMicros = _minimumEnrollmentSegmentMicros;
    final segmentStartMicros = _segmentStartMicros(segmentId);
    if (enrollment &&
        minimumEnrollmentMicros != null &&
        segmentStartMicros != null &&
        segmentStartMicros < minimumEnrollmentMicros) {
      state = 'waiting_for_enrollment_speech';
      log(
        'Conversation',
        '[WorkBench][Conversation] state=enrollment_segment_skipped '
            'reason=started_before_reset',
      );
      onChanged();
      return;
    }
    if (enrollment &&
        (_activeJobEnrollment || _jobs.any((job) => job.enrollment))) {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=enrollment_segment_skipped '
            'reason=sample_analysis_in_progress '
            'accepted=$acceptedEnrollmentSamples '
            'required=$requiredEnrollmentSamples',
      );
      onChanged();
      return;
    }
    if (enrollment) {
      _minimumEnrollmentSegmentMicros = null;
    }
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
    _activeJobEnrollment = job.enrollment;
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
    await _persistJobs();
    try {
      _profiles = retainBoundedSpeakerProfiles(result.profiles);
      await _recordStore.saveProfiles(_profiles);
      if (!result.enrollment) {
        final retained = await _recordStore.retainRecord(result.record);
        await _sharedAudioExportStore.indexConversation(retained);
        await _sharedAudioExportStore.exportFiles(<String>[retained.textPath]);
        completedConversations++;
      }
      final primary = _primaryProfile;
      if (result.enrollment &&
          (primary == null || primary.enrollmentInProgress)) {
        _enrollmentRequested = true;
        _minimumEnrollmentSegmentMicros = _nowMicros();
        state = 'waiting_for_enrollment_speech';
        error = null;
        log(
          'Conversation',
          '[WorkBench][Conversation] state=enrollment_waiting '
              'accepted=$acceptedEnrollmentSamples '
              'required=$requiredEnrollmentSamples',
        );
      } else {
        _enrollmentRequested = false;
        _minimumEnrollmentSegmentMicros = null;
        state = 'ready';
        error = null;
        if (result.enrollment && primary != null) {
          log(
            'Conversation',
            '[WorkBench][Conversation] state=enrollment_complete '
                'accepted=$requiredEnrollmentSamples '
                'signature_match_threshold='
                '${primary.signatureMatchThreshold.toStringAsFixed(3)}',
          );
        }
      }
    } catch (caught) {
      _fail(caught, stateName: 'storage_failed');
    } finally {
      _jobActive = false;
      _activeJobEnrollment = false;
      _dispatch();
      onChanged();
    }
  }

  void _onFailure(String segmentId, Object caught) {
    final failedEnrollment = _activeJobEnrollment;
    _removeJob(segmentId);
    _jobActive = false;
    _activeJobEnrollment = false;
    error = _oneLine(caught);
    state = failedEnrollment
        ? 'waiting_for_enrollment_speech'
        : 'analysis_failed';
    if (failedEnrollment || needsEnrollment) {
      _enrollmentRequested = true;
      _minimumEnrollmentSegmentMicros = _nowMicros();
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

  int _nowMicros() => _clock().toUtc().microsecondsSinceEpoch;

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
    final existing = _memoryPressureRelease;
    if (existing != null) {
      await existing;
      return;
    }
    final release = _releaseWorkerForMemoryPressure();
    _memoryPressureRelease = release;
    try {
      await release;
    } finally {
      if (identical(_memoryPressureRelease, release)) {
        _memoryPressureRelease = null;
      }
    }
  }

  Future<void> _releaseWorkerForMemoryPressure() async {
    final supervisor = _supervisor;
    _supervisor = null;
    _jobActive = false;
    _activeJobEnrollment = false;
    await supervisor?.dispose();
    if (_disposed) {
      return;
    }
    state = enabled ? 'paused_for_memory' : 'disabled';
    log(
      'Conversation',
      '[WorkBench][Conversation] state=$state '
          'capture=unaffected transcription=unaffected',
    );
    onChanged();
  }

  Future<void> resumeAfterMemoryPressure() async {
    await _memoryPressureRelease;
    if (enabled && _supervisor == null) {
      await _start();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _memoryPressureRelease;
    await _persistJobs();
    await _supervisor?.dispose();
    _supervisor = null;
  }
}

String _oneLine(Object value) =>
    '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();

int? _segmentStartMicros(String segmentId) {
  final separator = segmentId.indexOf('-');
  final prefix = separator < 0 ? segmentId : segmentId.substring(0, separator);
  final value = int.tryParse(prefix);
  return value == null || value < 1 ? null : value;
}
