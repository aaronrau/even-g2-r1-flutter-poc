import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

typedef SharedCorrectionInstructionsAvailable = bool Function();
typedef SharedCorrectionInstructionsReader = Future<String?> Function();
typedef SharedCorrectionInstructionsWriter =
    Future<void> Function(String instructions);

const defaultTranscriptCorrectionInstructions =
    'You correct short automatic speech recognition transcripts from smart '
    'glasses and return only corrected text. Preserve the speaker’s meaning '
    'and requested action. Correct obvious phonetic errors, command names, '
    'verbs, capitalization, punctuation, and light grammar. A leading local '
    'command name or attention word may be dropped or misheard. Use only the '
    'known command names and acoustic aliases supplied after these instructions; '
    'never invent a name. Restore a name only when the remaining words form a '
    'plausible imperative. With Flux supplied as a known name, for example, '
    '"Plus, all the latest changes." becomes "Flux, pull the latest changes." '
    'Ordinary prose such as "Plus, this is already complete." stays ordinary '
    'prose. Preserve numbers, paths, flags, identifiers, and uncertainty. Do '
    'not summarize, remove requested actions, add facts, answer the transcript, '
    'or use markdown.';

final class TranscriptCorrectionConfig {
  const TranscriptCorrectionConfig({
    required this.enabled,
    required this.instructions,
    this.modelId = 'gemma-4-e4b-it',
    this.backend = 'gpu',
    this.timeoutMs = 30000,
  });

  static const int schemaVersion = 1;
  static const int maximumInstructionCharacters = 2000;
  static const int minimumTimeoutMs = 5000;
  static const int maximumTimeoutMs = 120000;

  static const defaults = TranscriptCorrectionConfig(
    enabled: true,
    instructions: defaultTranscriptCorrectionInstructions,
  );

  final bool enabled;
  final String instructions;
  final String modelId;
  final String backend;
  final int timeoutMs;

  TranscriptCorrectionConfig copyWith({
    bool? enabled,
    String? instructions,
    String? modelId,
    String? backend,
    int? timeoutMs,
  }) => TranscriptCorrectionConfig(
    enabled: enabled ?? this.enabled,
    instructions: instructions ?? this.instructions,
    modelId: modelId ?? this.modelId,
    backend: backend ?? this.backend,
    timeoutMs: timeoutMs ?? this.timeoutMs,
  );

  Map<String, Object> toJson() => <String, Object>{
    'version': schemaVersion,
    'transcriptCorrection': <String, Object>{
      'enabled': enabled,
      'model': modelId,
      'backend': backend,
      'timeoutMs': timeoutMs,
      'instructions': instructions,
    },
  };

  static TranscriptCorrectionConfig fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('config.json must contain a JSON object.');
    }
    if (value['version'] != schemaVersion) {
      throw const FormatException('config.json version must be 1.');
    }
    final correction = value['transcriptCorrection'];
    if (correction is! Map<String, dynamic>) {
      throw const FormatException(
        'config.json must contain transcriptCorrection settings.',
      );
    }
    final enabled = correction['enabled'];
    final instructions = correction['instructions'];
    final model = correction['model'];
    final backend = correction['backend'];
    final timeoutMs = correction['timeoutMs'];
    if (enabled is! bool ||
        instructions is! String ||
        model is! String ||
        backend is! String ||
        timeoutMs is! int) {
      throw const FormatException(
        'Transcript correction settings have invalid value types.',
      );
    }
    if (model != 'gemma-4-e4b-it') {
      throw const FormatException(
        'Only the verified gemma-4-e4b-it model is supported.',
      );
    }
    if (backend != 'gpu') {
      throw const FormatException(
        'Transcript correction must use the fail-closed GPU backend.',
      );
    }
    if (timeoutMs < minimumTimeoutMs || timeoutMs > maximumTimeoutMs) {
      throw const FormatException(
        'Correction timeout must be between 5000 and 120000 milliseconds.',
      );
    }
    return TranscriptCorrectionConfig(
      enabled: enabled,
      instructions: validateInstructions(instructions),
      modelId: model,
      backend: backend,
      timeoutMs: timeoutMs,
    );
  }

  static String validateInstructions(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('LLM instructions cannot be empty.');
    }
    if (trimmed.length > maximumInstructionCharacters) {
      throw const FormatException(
        'LLM instructions cannot exceed 2000 characters.',
      );
    }
    for (final rune in trimmed.runes) {
      final allowedWhitespace = rune == 0x09 || rune == 0x0A || rune == 0x0D;
      if (rune < 0x20 && !allowedWhitespace) {
        throw const FormatException(
          'LLM instructions contain an unsupported control character.',
        );
      }
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is TranscriptCorrectionConfig &&
      other.enabled == enabled &&
      other.instructions == instructions &&
      other.modelId == modelId &&
      other.backend == backend &&
      other.timeoutMs == timeoutMs;

  @override
  int get hashCode =>
      Object.hash(enabled, instructions, modelId, backend, timeoutMs);
}

final class TranscriptCorrectionConfigStore extends ChangeNotifier {
  TranscriptCorrectionConfigStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    SharedCorrectionInstructionsAvailable? sharedInstructionsAvailable,
    SharedCorrectionInstructionsReader? sharedInstructionsReader,
    SharedCorrectionInstructionsWriter? sharedInstructionsWriter,
  }) : _supportDirectory = supportDirectory,
       _sharedInstructionsAvailable = sharedInstructionsAvailable,
       _sharedInstructionsReader = sharedInstructionsReader,
       _sharedInstructionsWriter = sharedInstructionsWriter;

  final Future<Directory> Function() _supportDirectory;
  final SharedCorrectionInstructionsAvailable? _sharedInstructionsAvailable;
  final SharedCorrectionInstructionsReader? _sharedInstructionsReader;
  final SharedCorrectionInstructionsWriter? _sharedInstructionsWriter;
  File? _file;
  Future<void> _operationTail = Future<void>.value();

  TranscriptCorrectionConfig config = TranscriptCorrectionConfig.defaults;
  String? validationError;

  Future<void> initialize() => _serialize(_initialize);

  Future<void> _initialize() async {
    final support = await _supportDirectory();
    final workbench = Directory('${support.path}/workbench');
    await workbench.create(recursive: true);
    _file = File('${workbench.path}/config.json');
    if (!await _file!.exists()) {
      await _write(config);
    } else {
      await _reloadPrivateConfig();
    }
    await _reloadSharedInstructions();
  }

  Future<TranscriptCorrectionConfig> reloadForNextTranscript() =>
      _serialize(() async {
        await _reloadPrivateConfig();
        await _reloadSharedInstructions();
        return config;
      });

  Future<void> _reloadPrivateConfig() async {
    final file = _file;
    if (file == null) {
      throw StateError(
        'Transcript correction configuration is not initialized.',
      );
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final loaded = TranscriptCorrectionConfig.fromJson(decoded);
      final changed = loaded != config || validationError != null;
      config = loaded;
      validationError = null;
      if (changed) {
        notifyListeners();
      }
    } on Object catch (error) {
      final message = _oneLine(error);
      if (validationError != message) {
        validationError = message;
        notifyListeners();
      }
      // The last validated snapshot remains active. A partial or externally
      // malformed config can never inject an unvalidated prompt into a job.
    }
  }

  Future<void> saveInstructions(String instructions) => _serialize(() async {
    final validated = TranscriptCorrectionConfig.validateInstructions(
      instructions,
    );
    final updated = config.copyWith(instructions: validated);
    if (_hasSharedInstructions) {
      await _sharedInstructionsWriter!(validated);
    }
    await _write(updated);
    config = updated;
    validationError = null;
    notifyListeners();
  });

  Future<void> setEnabled(bool enabled) => _serialize(() async {
    final updated = config.copyWith(enabled: enabled);
    await _write(updated);
    config = updated;
    validationError = null;
    notifyListeners();
  });

  Future<void> resetInstructions() =>
      saveInstructions(defaultTranscriptCorrectionInstructions);

  bool get _hasSharedInstructions =>
      (_sharedInstructionsAvailable?.call() ?? false) &&
      _sharedInstructionsReader != null &&
      _sharedInstructionsWriter != null;

  Future<void> _reloadSharedInstructions() async {
    if (!_hasSharedInstructions) {
      return;
    }
    try {
      final shared = await _sharedInstructionsReader!();
      if (shared == null) {
        await _sharedInstructionsWriter!(config.instructions);
        return;
      }
      final validated = TranscriptCorrectionConfig.validateInstructions(shared);
      final updated = config.copyWith(instructions: validated);
      if (updated != config) {
        await _write(updated);
      }
      final changed = updated != config || validationError != null;
      config = updated;
      validationError = null;
      if (changed) {
        notifyListeners();
      }
    } on Object catch (error) {
      final message = 'Shared correction prompt: ${_oneLine(error)}';
      if (validationError != message) {
        validationError = message;
        notifyListeners();
      }
      // A missing provider, partial external write, or invalid shared prompt
      // cannot replace the app-private last-known-good configuration.
    }
  }

  Future<void> _write(TranscriptCorrectionConfig value) async {
    final file = _file;
    if (file == null) {
      throw StateError(
        'Transcript correction configuration is not initialized.',
      );
    }
    final partial = File('${file.path}.part');
    final formatted = const JsonEncoder.withIndent(
      '  ',
    ).convert(value.toJson());
    await partial.writeAsString('$formatted\n', flush: true);
    // Android's POSIX rename replaces the old file atomically, so a reader
    // sees either the previous validated config or the complete new config.
    await partial.rename(file.path);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completion = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completion.complete(await operation());
      } on Object catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  static String _oneLine(Object value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}
