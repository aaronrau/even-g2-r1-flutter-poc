import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum WebSocketMessageDirection {
  sent,
  received;

  String get serializedName => name;
}

final class SavedWebSocketMessage {
  const SavedWebSocketMessage({
    required this.path,
    required this.fileName,
    required this.direction,
  });

  final String path;
  final String fileName;
  final WebSocketMessageDirection direction;
}

final class WebSocketMessageStore {
  WebSocketMessageStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    DateTime Function() now = DateTime.now,
  }) : _supportDirectory = supportDirectory,
       _now = now;

  static const int maximumMessageCharacters = 65536;
  static const String fileSuffix = '.message.txt';

  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;
  Directory? _directory;
  int _sequence = 0;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/workbench/websocket_messages');
    await directory.create(recursive: true);
    _directory = directory;
  }

  Future<SavedWebSocketMessage> save({
    required WebSocketMessageDirection direction,
    required String message,
  }) async {
    final directory = _directory;
    if (directory == null) {
      throw StateError('WebSocket message storage is not initialized.');
    }
    final normalized = _normalize(message);
    if (normalized.isEmpty) {
      throw const FormatException('WebSocket message cannot be empty.');
    }
    final receivedAt = _now().toUtc();
    late File target;
    late File partial;
    while (true) {
      _sequence++;
      final stamp = receivedAt.toIso8601String().replaceAll(
        RegExp(r'[-:.]'),
        '',
      );
      final base =
          'workbench-websocket-$stamp-'
          '${_sequence.toString().padLeft(4, '0')}';
      target = File(
        '${directory.path}/$base.${direction.serializedName}$fileSuffix',
      );
      partial = File('${directory.path}/$base.part.txt');
      if (!await target.exists() && !await partial.exists()) {
        break;
      }
    }
    await partial.writeAsString('$normalized\n', flush: true);
    await partial.rename(target.path);
    return SavedWebSocketMessage(
      path: target.path,
      fileName: target.uri.pathSegments.last,
      direction: direction,
    );
  }

  Future<List<String>> savedPaths() async {
    final directory = _directory;
    if (directory == null) {
      throw StateError('WebSocket message storage is not initialized.');
    }
    final paths = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith(fileSuffix))
        .map((entity) => entity.path)
        .toList();
    paths.sort();
    return paths;
  }

  static String _normalize(String value) {
    final output = StringBuffer();
    var characters = 0;
    final normalizedNewlines = value
        .trim()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    for (final rune in normalizedNewlines.runes) {
      if (characters >= maximumMessageCharacters) {
        break;
      }
      if (rune == 0x09 ||
          rune == 0x0A ||
          rune >= 0x20 && (rune < 0x7F || rune > 0x9F)) {
        output.writeCharCode(rune);
      }
      characters++;
    }
    return output.toString().trim();
  }
}
