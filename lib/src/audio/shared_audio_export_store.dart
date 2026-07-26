import 'dart:io';

import 'package:flutter/services.dart';

final class SharedAudioFolder {
  const SharedAudioFolder({required this.displayName});

  final String displayName;
}

final class SharedAudioExportStore {
  SharedAudioExportStore({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_storage',
    ),
    bool? isAndroid,
  }) : _channel = channel,
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  SharedAudioFolder? folder;

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
    }
    return selected;
  }

  Future<void> clearFolder() async {
    if (!_isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('clearDirectory');
    folder = null;
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

  SharedAudioFolder? _folderFromMessage(Map<String, Object?>? message) {
    final displayName = message?['displayName'];
    if (displayName is! String || displayName.trim().isEmpty) {
      return null;
    }
    return SharedAudioFolder(displayName: displayName.trim());
  }

  bool _isShareablePath(String path) {
    final lower = path.toLowerCase();
    return (lower.endsWith('.wav') || lower.endsWith('.txt')) &&
        !lower.endsWith('.part.wav') &&
        !lower.endsWith('.part.txt');
  }
}
