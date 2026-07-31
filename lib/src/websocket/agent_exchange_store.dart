import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

final class AgentExchangeView {
  const AgentExchangeView({
    required this.id,
    required this.agent,
    required this.message,
    required this.sentAt,
    required this.legacy,
    this.response,
  });

  final String id;
  final String agent;
  final String message;
  final DateTime sentAt;
  final bool legacy;
  final String? response;
}

final class AgentExchangeStore {
  AgentExchangeStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    DateTime Function() now = DateTime.now,
  }) : _supportDirectory = supportDirectory,
       _now = now;

  static const int maximumExchanges = 32;

  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;
  final List<_AgentExchangeRecord> _records = <_AgentExchangeRecord>[];
  final Map<String, _PendingResponse> _orphanResponses =
      <String, _PendingResponse>{};
  File? _file;
  int _sequence = 0;
  bool _legacyImportComplete = false;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/workbench');
    await directory.create(recursive: true);
    _file = File('${directory.path}/agent_exchanges.json');
    _records.clear();
    final file = _file!;
    if (!await file.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported exchange ledger.');
      }
      final records = decoded['exchanges'];
      if (records is! List<dynamic>) {
        throw const FormatException('Invalid exchange ledger.');
      }
      for (final value in records) {
        if (value is Map<String, dynamic>) {
          _records.add(_AgentExchangeRecord.fromJson(value));
        }
      }
      _legacyImportComplete = decoded['legacy_import_complete'] == true;
      _records.sort((a, b) => b.sentAt.compareTo(a.sentAt));
      if (_records.length > maximumExchanges) {
        _records.removeRange(maximumExchanges, _records.length);
      }
    } on Object {
      final invalid = File('${file.path}.invalid');
      if (await invalid.exists()) {
        await invalid.delete();
      }
      await file.rename(invalid.path);
      _records.clear();
      _legacyImportComplete = false;
    }
  }

  Future<void> importExistingSentMessages({
    required List<String> paths,
    required List<String> agents,
    required bool legacy,
  }) async {
    _requireInitialized();
    if (_legacyImportComplete || agents.isEmpty) {
      return;
    }
    final normalizedAgents = <String, String>{
      for (final agent in agents)
        if (agent.trim().isNotEmpty) agent.trim().toLowerCase(): agent.trim(),
    };
    final importedAgents = <String>{};
    for (final path in paths.reversed) {
      if (importedAgents.length >= normalizedAgents.length ||
          _records.length >= maximumExchanges) {
        break;
      }
      if (!path.endsWith('.sent.message.txt')) {
        continue;
      }
      final file = File(path);
      try {
        final text = (await file.readAsString()).trim();
        String? matchedKey;
        String? matchedAgent;
        for (final entry in normalizedAgents.entries) {
          if (!importedAgents.contains(entry.key) &&
              text.toLowerCase().startsWith('${entry.key}:')) {
            matchedKey = entry.key;
            matchedAgent = entry.value;
            break;
          }
        }
        if (matchedKey == null || matchedAgent == null) {
          continue;
        }
        importedAgents.add(matchedKey);
        final sentAt = (await file.lastModified()).toUtc();
        _sequence++;
        _records.add(
          _AgentExchangeRecord(
            id: 'import-${sentAt.microsecondsSinceEpoch}-$_sequence',
            agent: matchedAgent,
            sentMessagePath: path,
            sentAt: sentAt,
            legacy: legacy,
          ),
        );
      } on Object {
        // One missing or unreadable historical file cannot block the one-time
        // migration of other durable messages.
      }
    }
    _records.sort((a, b) => b.sentAt.compareTo(a.sentAt));
    _legacyImportComplete = true;
    await _persist();
  }

  Future<String> recordSent({
    required String agent,
    required String messagePath,
    required bool legacy,
    String? requestId,
  }) async {
    _requireInitialized();
    final now = _now().toUtc();
    _sequence++;
    final id = '${now.microsecondsSinceEpoch}-$_sequence';
    final record = _AgentExchangeRecord(
      id: id,
      agent: agent.trim(),
      sentMessagePath: messagePath,
      sentAt: now,
      legacy: legacy,
      deliveryRequestId: requestId,
    );
    final orphan = requestId == null
        ? null
        : _orphanResponses.remove(requestId);
    if (orphan != null) {
      record
        ..responsePath = orphan.path
        ..responseAt = orphan.receivedAt
        ..responseKind = orphan.kind;
    }
    _records.insert(0, record);
    if (_records.length > maximumExchanges) {
      _records.removeRange(maximumExchanges, _records.length);
    }
    await _persist();
    return id;
  }

  Future<void> associateSummary({
    required String exchangeId,
    String? requestId,
  }) async {
    final record = _recordById(exchangeId);
    record.pendingSummaryRequestId = requestId;
    final orphan = requestId == null
        ? null
        : _orphanResponses.remove(requestId);
    if (orphan != null) {
      record
        ..responsePath = orphan.path
        ..responseAt = orphan.receivedAt
        ..responseKind = orphan.kind
        ..pendingSummaryRequestId = null;
    }
    await _persist();
  }

  Future<String?> attachResponse({
    required String responsePath,
    required String kind,
    String? requestId,
    String? agent,
    bool allowLegacyAgentMatch = false,
  }) async {
    _requireInitialized();
    _AgentExchangeRecord? record;
    if (requestId != null && requestId.trim().isNotEmpty) {
      final normalized = requestId.trim();
      record = _records.cast<_AgentExchangeRecord?>().firstWhere(
        (candidate) =>
            candidate?.deliveryRequestId == normalized ||
            candidate?.pendingSummaryRequestId == normalized,
        orElse: () => null,
      );
      if (record == null) {
        _orphanResponses[normalized] = _PendingResponse(
          path: responsePath,
          kind: kind,
          receivedAt: _now().toUtc(),
        );
        while (_orphanResponses.length > maximumExchanges) {
          _orphanResponses.remove(_orphanResponses.keys.first);
        }
        return null;
      }
    } else if (allowLegacyAgentMatch && agent != null) {
      final normalized = agent.trim().toLowerCase();
      record = _records.cast<_AgentExchangeRecord?>().firstWhere(
        (candidate) =>
            candidate?.legacy == true &&
            candidate?.agent.toLowerCase() == normalized,
        orElse: () => null,
      );
    }
    if (record == null) {
      return null;
    }
    record
      ..responsePath = responsePath
      ..responseAt = _now().toUtc()
      ..responseKind = kind
      ..pendingSummaryRequestId = null;
    await _persist();
    return record.id;
  }

  Future<List<AgentExchangeView>> latestForAgents(
    List<String> agents, {
    int maximumAgents = 5,
  }) async {
    _requireInitialized();
    final selected = <_AgentExchangeRecord>[];
    final configured = agents
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    final latestByAgent = <String, _AgentExchangeRecord>{};
    for (final record in _records) {
      latestByAgent.putIfAbsent(record.agent.toLowerCase(), () => record);
    }
    final ranked = configured.toList(growable: false)
      ..sort((a, b) {
        final aTime = latestByAgent[a.toLowerCase()]?.sentAt;
        final bTime = latestByAgent[b.toLowerCase()]?.sentAt;
        if (aTime == null && bTime == null) {
          return agents.indexOf(a).compareTo(agents.indexOf(b));
        }
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
    final chosen = ranked.take(maximumAgents).toSet();
    for (final agent in agents) {
      if (!chosen.contains(agent)) {
        continue;
      }
      final record = latestByAgent[agent.toLowerCase()];
      if (record != null) {
        selected.add(record);
      }
    }
    final views = <AgentExchangeView>[];
    for (final record in selected) {
      views.add(await _readView(record));
    }
    return views;
  }

  Future<AgentExchangeView?> viewById(String exchangeId) async {
    _requireInitialized();
    final record = _records.cast<_AgentExchangeRecord?>().firstWhere(
      (candidate) => candidate?.id == exchangeId,
      orElse: () => null,
    );
    return record == null ? null : _readView(record);
  }

  Future<void> clear() async {
    _requireInitialized();
    _records.clear();
    _orphanResponses.clear();
    _legacyImportComplete = true;
    await _persist();
  }

  Future<AgentExchangeView> _readView(_AgentExchangeRecord record) async {
    final sent = await _readText(record.sentMessagePath);
    final prefix = '${record.agent}:';
    final message = sent.toLowerCase().startsWith(prefix.toLowerCase())
        ? sent.substring(prefix.length).trim()
        : sent;
    final responsePath = record.responsePath;
    return AgentExchangeView(
      id: record.id,
      agent: record.agent,
      message: message,
      sentAt: record.sentAt,
      legacy: record.legacy,
      response: responsePath == null ? null : await _readText(responsePath),
    );
  }

  Future<String> _readText(String path) async {
    try {
      return (await File(path).readAsString()).trim();
    } on Object {
      return '';
    }
  }

  _AgentExchangeRecord _recordById(String id) =>
      _records.cast<_AgentExchangeRecord?>().firstWhere(
        (candidate) => candidate?.id == id,
        orElse: () => null,
      ) ??
      (throw StateError('The selected exchange is no longer available.'));

  Future<void> _persist() async {
    final file = _file!;
    final partial = File('${file.path}.part');
    final encoded = const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'version': 1,
      'legacy_import_complete': _legacyImportComplete,
      'exchanges': _records
          .map((record) => record.toJson())
          .toList(growable: false),
    });
    await partial.writeAsString('$encoded\n', flush: true);
    await partial.rename(file.path);
  }

  void _requireInitialized() {
    if (_file == null) {
      throw StateError('Agent exchange storage is not initialized.');
    }
  }
}

final class _PendingResponse {
  const _PendingResponse({
    required this.path,
    required this.kind,
    required this.receivedAt,
  });

  final String path;
  final String kind;
  final DateTime receivedAt;
}

final class _AgentExchangeRecord {
  _AgentExchangeRecord({
    required this.id,
    required this.agent,
    required this.sentMessagePath,
    required this.sentAt,
    required this.legacy,
    this.deliveryRequestId,
    this.responsePath,
    this.responseAt,
    this.responseKind,
    this.pendingSummaryRequestId,
  });

  factory _AgentExchangeRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final agent = json['agent'];
    final sentMessagePath = json['sent_message_path'];
    final sentAt = DateTime.tryParse('${json['sent_at']}');
    final legacy = json['legacy'];
    if (id is! String ||
        id.isEmpty ||
        agent is! String ||
        agent.isEmpty ||
        sentMessagePath is! String ||
        sentMessagePath.isEmpty ||
        sentAt == null ||
        legacy is! bool) {
      throw const FormatException('Invalid exchange record.');
    }
    return _AgentExchangeRecord(
      id: id,
      agent: agent,
      sentMessagePath: sentMessagePath,
      sentAt: sentAt.toUtc(),
      legacy: legacy,
      deliveryRequestId: json['delivery_request_id'] as String?,
      responsePath: json['response_path'] as String?,
      responseAt: json['response_at'] == null
          ? null
          : DateTime.tryParse('${json['response_at']}')?.toUtc(),
      responseKind: json['response_kind'] as String?,
      pendingSummaryRequestId: json['pending_summary_request_id'] as String?,
    );
  }

  final String id;
  final String agent;
  final String sentMessagePath;
  final DateTime sentAt;
  final bool legacy;
  final String? deliveryRequestId;
  String? responsePath;
  DateTime? responseAt;
  String? responseKind;
  String? pendingSummaryRequestId;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'agent': agent,
    'sent_message_path': sentMessagePath,
    'sent_at': sentAt.toUtc().toIso8601String(),
    'legacy': legacy,
    'delivery_request_id': deliveryRequestId,
    'response_path': responsePath,
    'response_at': responseAt?.toUtc().toIso8601String(),
    'response_kind': responseKind,
    'pending_summary_request_id': pendingSummaryRequestId,
  };
}
