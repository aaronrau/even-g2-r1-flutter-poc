import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'voice_memo_models.dart';

final class VoiceMemoStore {
  VoiceMemoStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  final Future<Directory> Function() _supportDirectory;
  Directory? _root;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    _root = Directory('${support.path}/workbench/memos');
    await _root!.create(recursive: true);
  }

  Future<List<VoiceMemoRecord>> loadRecords() async {
    final records = <VoiceMemoRecord>[];
    await for (final entity in _requireRoot().list()) {
      if (entity is! File || !entity.path.endsWith('.memo.json')) {
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map<String, Object?>) {
          records.add(VoiceMemoRecord.fromJson(decoded));
        }
      } on Object {
        continue;
      }
    }
    records.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return records;
  }

  Future<void> save(VoiceMemoRecord record) async {
    final root = _requireRoot();
    final metadata = File('${root.path}/${record.id}.memo.json');
    final note = File('${root.path}/${record.id}.memo.txt');
    await _atomicWrite(metadata, '${record.encode()}\n');
    await _atomicWrite(note, '${record.note.trim()}\n');
  }

  Directory _requireRoot() {
    final root = _root;
    if (root == null) {
      throw StateError('Voice memo storage is not initialized.');
    }
    return root;
  }

  Future<void> _atomicWrite(File target, String value) async {
    final partial = File('${target.path}.part');
    if (await partial.exists()) {
      await partial.delete();
    }
    await partial.writeAsString(value, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await partial.rename(target.path);
  }
}
