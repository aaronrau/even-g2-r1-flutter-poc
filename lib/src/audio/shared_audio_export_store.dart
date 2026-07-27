import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final class SharedAudioFolder {
  const SharedAudioFolder({required this.displayName});

  final String displayName;
}

final class SharedTranscript {
  const SharedTranscript({
    required this.id,
    required this.originalText,
    required this.updatedAt,
    this.correctedText,
    this.audioFileName,
  });

  final String id;
  final String originalText;
  final String? correctedText;
  final DateTime updatedAt;
  final String? audioFileName;

  bool get hasAudio => audioFileName != null;
  bool get hasCorrection => correctedText != null;
  String get text => correctedText ?? originalText;
}

final class SharedAudioExportStore extends ChangeNotifier {
  SharedAudioExportStore({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_storage',
    ),
    bool? isAndroid,
  }) : _channel = channel,
       _isAndroid = isAndroid ?? Platform.isAndroid {
    if (_isAndroid) {
      _channel.setMethodCallHandler(_handlePlatformCall);
    }
  }

  final MethodChannel _channel;
  final bool _isAndroid;

  SharedAudioFolder? folder;
  List<SharedTranscript> transcripts = const <SharedTranscript>[];
  bool isLoadingTranscripts = false;
  String? transcriptLoadError;
  String? playingAudioFileName;

  bool get isSupported => _isAndroid;
  bool get hasSharedFolder => folder != null;

  Future<void> initialize() async {
    if (!_isAndroid) {
      return;
    }
    folder = _folderFromMessage(
      await _channel.invokeMapMethod<String, Object?>('currentDirectory'),
    );
  }

  Future<SharedAudioFolder?> chooseFolder() async {
    if (!_isAndroid) {
      throw UnsupportedError(
        'Shared audio folders are currently available on Android.',
      );
    }
    final selected = _folderFromMessage(
      await _channel.invokeMapMethod<String, Object?>('chooseDirectory'),
    );
    if (selected != null) {
      folder = selected;
      transcripts = const <SharedTranscript>[];
      transcriptLoadError = null;
      notifyListeners();
    }
    return selected;
  }

  Future<void> clearFolder() async {
    if (!_isAndroid) {
      return;
    }
    await stopAudio();
    await _channel.invokeMethod<void>('clearDirectory');
    folder = null;
    transcripts = const <SharedTranscript>[];
    transcriptLoadError = null;
    notifyListeners();
  }

  Future<int> exportFiles(Iterable<String> paths) async {
    if (!_isAndroid || folder == null) {
      return 0;
    }
    final stablePaths = paths
        .where(_isShareablePath)
        .toSet()
        .toList(growable: false);
    if (stablePaths.isEmpty) {
      return 0;
    }
    final exported = await _channel.invokeMethod<int>(
      'exportFiles',
      <String, Object>{'paths': stablePaths},
    );
    return exported ?? 0;
  }

  Future<void> refreshTranscriptions() async {
    if (!_isAndroid || folder == null) {
      transcripts = const <SharedTranscript>[];
      transcriptLoadError = null;
      notifyListeners();
      return;
    }
    isLoadingTranscripts = true;
    transcriptLoadError = null;
    notifyListeners();
    try {
      final messages =
          await _channel.invokeMethod<List<Object?>>('listTranscriptions') ??
          const <Object?>[];
      final loaded = messages
          .whereType<Map<Object?, Object?>>()
          .map(_transcriptFromMessage)
          .whereType<SharedTranscript>()
          .toList(growable: false);
      loaded.sort((left, right) {
        final byTime = right.updatedAt.compareTo(left.updatedAt);
        return byTime != 0 ? byTime : right.id.compareTo(left.id);
      });
      transcripts = loaded;
    } catch (_) {
      transcriptLoadError =
          'Could not read the selected folder. Choose it again or retry.';
      rethrow;
    } finally {
      isLoadingTranscripts = false;
      notifyListeners();
    }
  }

  Future<void> toggleAudio(SharedTranscript transcript) async {
    final audioFileName = transcript.audioFileName;
    if (!_isAndroid || audioFileName == null) {
      return;
    }
    if (playingAudioFileName == audioFileName) {
      await stopAudio();
      return;
    }
    playingAudioFileName = audioFileName;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('playAudio', <String, Object>{
        'fileName': audioFileName,
      });
    } catch (_) {
      if (playingAudioFileName == audioFileName) {
        playingAudioFileName = null;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> stopAudio() async {
    if (!_isAndroid || playingAudioFileName == null) {
      return;
    }
    await _channel.invokeMethod<void>('stopAudio');
    playingAudioFileName = null;
    notifyListeners();
  }

  SharedAudioFolder? _folderFromMessage(Map<String, Object?>? message) {
    final displayName = message?['displayName'];
    if (displayName is! String || displayName.trim().isEmpty) {
      return null;
    }
    return SharedAudioFolder(displayName: displayName.trim());
  }

  SharedTranscript? _transcriptFromMessage(Map<Object?, Object?> message) {
    final id = message['id'];
    final originalText = message['originalText'];
    final correctedText = message['correctedText'];
    final updatedAtMillis = message['updatedAtMillis'];
    if (id is! String ||
        id.trim().isEmpty ||
        originalText is! String ||
        originalText.trim().isEmpty ||
        updatedAtMillis is! int) {
      return null;
    }
    final audioFileName = message['audioFileName'];
    return SharedTranscript(
      id: id.trim(),
      originalText: originalText.trim(),
      correctedText: correctedText is String && correctedText.trim().isNotEmpty
          ? correctedText.trim()
          : null,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
      audioFileName: audioFileName is String && audioFileName.trim().isNotEmpty
          ? audioFileName.trim()
          : null,
    );
  }

  Future<void> _handlePlatformCall(MethodCall call) async {
    if (call.method != 'playbackCompleted') {
      return;
    }
    final arguments = call.arguments;
    final fileName = arguments is Map<Object?, Object?>
        ? arguments['fileName']
        : null;
    if (fileName == playingAudioFileName) {
      playingAudioFileName = null;
      notifyListeners();
    }
  }

  bool _isShareablePath(String path) {
    final lower = path.toLowerCase();
    return (lower.endsWith('.wav') || lower.endsWith('.txt')) &&
        !lower.endsWith('.part.wav') &&
        !lower.endsWith('.part.txt');
  }

  Future<void> _stopAudioForDispose() async {
    try {
      await _channel.invokeMethod<void>('stopAudio');
    } catch (_) {
      // The Flutter engine may already be detaching during app shutdown.
    }
  }

  @override
  void dispose() {
    if (_isAndroid) {
      if (playingAudioFileName != null) {
        unawaited(_stopAudioForDispose());
      }
      playingAudioFileName = null;
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
