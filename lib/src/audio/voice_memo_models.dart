import 'dart:convert';

enum VoiceMemoStatus { listening, revising, finalizing, finalized, interrupted }

extension VoiceMemoStatusLabel on VoiceMemoStatus {
  String get label => switch (this) {
    VoiceMemoStatus.listening => 'Listening',
    VoiceMemoStatus.revising => 'Updating',
    VoiceMemoStatus.finalizing => 'Finalizing',
    VoiceMemoStatus.finalized => 'Saved',
    VoiceMemoStatus.interrupted => 'Interrupted',
  };
}

final class VoiceMemoSource {
  const VoiceMemoSource({
    required this.segmentId,
    required this.rawTranscript,
    required this.memoText,
    this.finalTranscript,
  });

  factory VoiceMemoSource.fromJson(Map<String, Object?> json) {
    final segmentId = json['segmentId'];
    final rawTranscript = json['rawTranscript'];
    final memoText = json['memoText'];
    final finalTranscript = json['finalTranscript'];
    if (segmentId is! String ||
        segmentId.trim().isEmpty ||
        rawTranscript is! String ||
        memoText is! String ||
        (finalTranscript != null && finalTranscript is! String)) {
      throw const FormatException('The saved memo source is invalid.');
    }
    return VoiceMemoSource(
      segmentId: segmentId.trim(),
      rawTranscript: rawTranscript.trim(),
      memoText: memoText.trim(),
      finalTranscript: (finalTranscript as String?)?.trim(),
    );
  }

  final String segmentId;
  final String rawTranscript;
  final String memoText;
  final String? finalTranscript;

  VoiceMemoSource withFinalTranscript({
    required String transcript,
    required String text,
  }) => VoiceMemoSource(
    segmentId: segmentId,
    rawTranscript: rawTranscript,
    memoText: text.trim(),
    finalTranscript: transcript.trim(),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'segmentId': segmentId,
    'rawTranscript': rawTranscript,
    'memoText': memoText,
    'finalTranscript': finalTranscript,
  };
}

final class VoiceMemoRecord {
  const VoiceMemoRecord({
    required this.id,
    required this.status,
    required this.note,
    required this.sources,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.finalizedAt,
    this.errorCode,
  });

  factory VoiceMemoRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final status = VoiceMemoStatus.values
        .where((value) => value.name == json['status'])
        .firstOrNull;
    final note = json['note'];
    final sources = json['sources'];
    final revision = json['revision'];
    final createdAt = DateTime.tryParse('${json['createdAt']}');
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    final finalizedAtValue = json['finalizedAt'];
    final finalizedAt = finalizedAtValue == null
        ? null
        : DateTime.tryParse('$finalizedAtValue');
    final errorCode = json['errorCode'];
    if (id is! String ||
        id.trim().isEmpty ||
        status == null ||
        note is! String ||
        sources is! List<Object?> ||
        revision is! int ||
        revision < 0 ||
        createdAt == null ||
        updatedAt == null ||
        (finalizedAtValue != null && finalizedAt == null) ||
        (errorCode != null && errorCode is! String)) {
      throw const FormatException('The saved memo is invalid.');
    }
    return VoiceMemoRecord(
      id: id.trim(),
      status: status,
      note: note.trim(),
      sources: sources
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => VoiceMemoSource.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false),
      revision: revision,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      finalizedAt: finalizedAt?.toUtc(),
      errorCode: (errorCode as String?)?.trim(),
    );
  }

  final String id;
  final VoiceMemoStatus status;
  final String note;
  final List<VoiceMemoSource> sources;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? finalizedAt;
  final String? errorCode;

  bool get isActive =>
      status == VoiceMemoStatus.listening ||
      status == VoiceMemoStatus.revising ||
      status == VoiceMemoStatus.finalizing;

  VoiceMemoRecord copyWith({
    VoiceMemoStatus? status,
    String? note,
    List<VoiceMemoSource>? sources,
    int? revision,
    DateTime? updatedAt,
    DateTime? finalizedAt,
    String? errorCode,
    bool clearError = false,
  }) => VoiceMemoRecord(
    id: id,
    status: status ?? this.status,
    note: note ?? this.note,
    sources: sources ?? this.sources,
    revision: revision ?? this.revision,
    createdAt: createdAt,
    updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
    finalizedAt: finalizedAt ?? this.finalizedAt,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'id': id,
    'status': status.name,
    'note': note,
    'sources': sources.map((source) => source.toJson()).toList(growable: false),
    'revision': revision,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'finalizedAt': finalizedAt?.toUtc().toIso8601String(),
    'errorCode': errorCode,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

final class MemoInvocation {
  const MemoInvocation({required this.body});

  static final RegExp _pattern = RegExp(
    r'^\s*hey[\s,.;:!?-]+memo\b[\s,.;:!?-]*(.*)$',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _supportedAcousticVariant = RegExp(
    r'^\s*hey[\s,.;:!?-]+(?:me[\s,.;:!?-]+mo|mimo)\b',
    caseSensitive: false,
  );

  final String body;

  static MemoInvocation? parse(String transcript) {
    final match = _pattern.firstMatch(transcript);
    if (match == null) {
      return null;
    }
    return MemoInvocation(body: (match.group(1) ?? '').trim());
  }

  /// Whether raw STT contains both the attention word and memo-like acoustic
  /// evidence. Corrected text may normalize that evidence, but it may not
  /// expand a standalone "Hey" into the complete invocation.
  static bool hasWakeEvidence(String rawTranscript) =>
      parse(rawTranscript) != null ||
      _supportedAcousticVariant.hasMatch(rawTranscript);
}
