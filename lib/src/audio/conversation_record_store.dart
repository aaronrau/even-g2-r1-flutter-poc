import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'conversation_models.dart';

final class ConversationRecordStore {
  ConversationRecordStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  final Future<Directory> Function() _supportDirectory;
  Directory? _root;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    _root = Directory('${support.path}/workbench/conversation');
    await _root!.create(recursive: true);
  }

  Future<List<SpeakerProfile>> loadProfiles() async {
    final file = File('${_requireRoot().path}/speaker-profiles.json');
    if (!await file.exists()) {
      return const <SpeakerProfile>[];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['profiles'] is! List<Object?>) {
        throw const FormatException('Invalid speaker profile document.');
      }
      return (decoded['profiles']! as List<Object?>)
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => SpeakerProfile.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false);
    } on Object {
      final invalid = File('${file.path}.invalid');
      if (await invalid.exists()) {
        await invalid.delete();
      }
      await file.rename(invalid.path);
      return const <SpeakerProfile>[];
    }
  }

  Future<void> saveProfiles(Iterable<SpeakerProfile> profiles) async {
    final file = File('${_requireRoot().path}/speaker-profiles.json');
    await _atomicWrite(
      file,
      '${const JsonEncoder.withIndent('  ').convert(<String, Object>{'version': 1, 'profiles': profiles.map((profile) => profile.toJson()).toList(growable: false)})}\n',
    );
  }

  Future<List<ConversationRecord>> loadRecords() async {
    final records = <ConversationRecord>[];
    await for (final entity in _requireRoot().list()) {
      if (entity is! File || !entity.path.endsWith('.conversation.json')) {
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map<String, Object?>) {
          records.add(ConversationRecord.fromJson(decoded));
        }
      } on Object {
        continue;
      }
    }
    records.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return records;
  }

  Future<List<ConversationPendingJob>> loadPendingJobs() async {
    final file = File('${_requireRoot().path}/pending-jobs.json');
    if (!await file.exists()) {
      return const <ConversationPendingJob>[];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['jobs'] is! List<Object?>) {
        throw const FormatException('Invalid conversation job document.');
      }
      final jobs = (decoded['jobs']! as List<Object?>)
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => ConversationPendingJob.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .where((job) => File(job.wavPath).existsSync())
          .toList(growable: false);
      return jobs;
    } on Object {
      return const <ConversationPendingJob>[];
    }
  }

  Future<void> savePendingJobs(Iterable<ConversationPendingJob> jobs) async {
    final file = File('${_requireRoot().path}/pending-jobs.json');
    await _atomicWrite(
      file,
      '${const JsonEncoder.withIndent('  ').convert(<String, Object>{'version': 1, 'jobs': jobs.map((job) => job.toJson()).toList(growable: false)})}\n',
    );
  }

  Future<ConversationRecord> retainRecord(ConversationRecord source) async {
    final metadata = File(
      '${_requireRoot().path}/${source.id}.conversation.json',
    );
    final retained = ConversationRecord(
      id: source.id,
      audioPath: source.audioPath,
      textPath: source.textPath,
      metadataPath: metadata.path,
      utterances: source.utterances,
      updatedAt: source.updatedAt,
    );
    await _atomicWrite(metadata, '${retained.encode()}\n');
    return retained;
  }

  Future<void> clearProfiles() async {
    await saveProfiles(const <SpeakerProfile>[]);
  }

  Directory _requireRoot() {
    final root = _root;
    if (root == null) {
      throw StateError('Conversation storage is not initialized.');
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
