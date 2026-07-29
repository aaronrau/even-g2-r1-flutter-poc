import 'dart:convert';
import 'dart:math';

const int maximumNonPrimarySpeakerProfiles = 16;
// Lower than the legacy 0.65 cutoff while remaining above the pinned
// af_maple/af_sol near-collision measured at 0.6390.
const double defaultSpeakerSignatureMatchThreshold = 0.64;
const double speakerSignatureLearningThreshold = 0.78;

final class ConversationModelPaths {
  const ConversationModelPaths({
    required this.segmentation,
    required this.embedding,
  });

  final String segmentation;
  final String embedding;

  Map<String, Object> toMessage() => <String, Object>{
    'segmentation': segmentation,
    'embedding': embedding,
  };
}

final class ConversationPendingJob {
  const ConversationPendingJob({
    required this.segmentId,
    required this.wavPath,
    required this.enrollment,
    required this.queuedAt,
  });

  factory ConversationPendingJob.fromJson(Map<String, Object?> json) {
    final segmentId = json['segmentId'];
    final wavPath = json['wavPath'];
    final queuedAt = DateTime.tryParse('${json['queuedAt']}');
    if (segmentId is! String ||
        segmentId.trim().isEmpty ||
        wavPath is! String ||
        wavPath.trim().isEmpty ||
        queuedAt == null) {
      throw const FormatException('The saved conversation job is invalid.');
    }
    return ConversationPendingJob(
      segmentId: segmentId.trim(),
      wavPath: wavPath.trim(),
      enrollment: json['enrollment'] == true,
      queuedAt: queuedAt.toUtc(),
    );
  }

  final String segmentId;
  final String wavPath;
  final bool enrollment;
  final DateTime queuedAt;

  Map<String, Object> toJson() => <String, Object>{
    'segmentId': segmentId,
    'wavPath': wavPath,
    'enrollment': enrollment,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
  };
}

final class SpeakerProfile {
  const SpeakerProfile({
    required this.id,
    required this.label,
    required this.embedding,
    required this.sampleCount,
    required this.createdAt,
    required this.updatedAt,
    this.signatures = const <List<double>>[],
    this.isPrimary = false,
  });

  factory SpeakerProfile.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final label = json['label'];
    final embedding = json['embedding'];
    final sampleCount = json['sampleCount'];
    final createdAt = DateTime.tryParse('${json['createdAt']}');
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String ||
        id.trim().isEmpty ||
        label is! String ||
        label.trim().isEmpty ||
        embedding is! List<Object?> ||
        embedding.isEmpty ||
        sampleCount is! int ||
        sampleCount < 1 ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException('The saved speaker profile is invalid.');
    }
    final values = embedding
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList(growable: false);
    if (values.length != embedding.length ||
        values.any((value) => !value.isFinite)) {
      throw const FormatException('The saved speaker signature is invalid.');
    }
    final rawSignatures = json['signatures'];
    final signatures = <List<double>>[];
    if (rawSignatures != null) {
      if (rawSignatures is! List<Object?>) {
        throw const FormatException(
          'The saved speaker signature bank is invalid.',
        );
      }
      for (final rawSignature in rawSignatures) {
        if (rawSignature is! List<Object?>) {
          throw const FormatException(
            'The saved speaker signature bank is invalid.',
          );
        }
        final signature = rawSignature
            .whereType<num>()
            .map((value) => value.toDouble())
            .toList(growable: false);
        if (signature.length != values.length ||
            signature.length != rawSignature.length ||
            signature.any((value) => !value.isFinite)) {
          throw const FormatException(
            'The saved speaker signature bank is invalid.',
          );
        }
        signatures.add(signature);
      }
    }
    return SpeakerProfile(
      id: id.trim(),
      label: label.trim(),
      embedding: values,
      signatures: signatures,
      sampleCount: sampleCount,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      isPrimary: json['isPrimary'] == true,
    );
  }

  final String id;
  final String label;
  final List<double> embedding;
  final List<List<double>> signatures;
  final int sampleCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPrimary;

  SpeakerProfile merge(List<double> candidate, DateTime now) {
    if (candidate.length != embedding.length ||
        candidate.any((value) => !value.isFinite)) {
      return this;
    }
    final nextCount = min(sampleCount + 1, 20);
    final retainedWeight = nextCount - 1;
    final merged = List<double>.generate(
      embedding.length,
      (index) =>
          (embedding[index] * retainedWeight + candidate[index]) / nextCount,
      growable: false,
    );
    final retainedSignatures = signatures.isEmpty
        ? <List<double>>[embedding]
        : signatures;
    final nextSignatures = <List<double>>[
      ...retainedSignatures,
      normalizeSpeakerEmbedding(candidate),
    ];
    if (nextSignatures.length > 6) {
      nextSignatures.removeRange(0, nextSignatures.length - 6);
    }
    return SpeakerProfile(
      id: id,
      label: label,
      embedding: normalizeSpeakerEmbedding(merged),
      signatures: nextSignatures,
      sampleCount: nextCount,
      createdAt: createdAt,
      updatedAt: now.toUtc(),
      isPrimary: isPrimary,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'label': label,
    'embedding': embedding,
    'signatures': signatures.isEmpty ? <List<double>>[embedding] : signatures,
    'sampleCount': sampleCount,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'isPrimary': isPrimary,
  };
}

List<SpeakerProfile> retainNonPrimarySpeakerProfiles(
  Iterable<SpeakerProfile> profiles,
) => List<SpeakerProfile>.unmodifiable(
  profiles.where((profile) => !profile.isPrimary),
);

/// Keeps one primary profile and a bounded, most-recent non-primary bank.
///
/// Profile matching runs for every finalized segment, so an unbounded bank
/// would increase both memory and analysis time indefinitely. Duplicate IDs
/// and older duplicate primary records are also removed during compaction.
List<SpeakerProfile> retainBoundedSpeakerProfiles(
  Iterable<SpeakerProfile> profiles, {
  int maximumNonPrimary = maximumNonPrimarySpeakerProfiles,
}) {
  if (maximumNonPrimary < 0) {
    throw ArgumentError.value(
      maximumNonPrimary,
      'maximumNonPrimary',
      'The maximum must not be negative.',
    );
  }
  final newestById = <String, SpeakerProfile>{};
  for (final profile in profiles) {
    final retained = newestById[profile.id];
    if (retained == null ||
        profile.updatedAt.isAfter(retained.updatedAt) ||
        (profile.updatedAt == retained.updatedAt &&
            profile.sampleCount > retained.sampleCount)) {
      newestById[profile.id] = profile;
    }
  }
  final primaries =
      newestById.values
          .where((profile) => profile.isPrimary)
          .toList(growable: false)
        ..sort(_compareSpeakerProfileRetention);
  final others =
      newestById.values
          .where((profile) => !profile.isPrimary)
          .toList(growable: false)
        ..sort(_compareSpeakerProfileRetention);
  return List<SpeakerProfile>.unmodifiable(<SpeakerProfile>[
    if (primaries.isNotEmpty) primaries.first,
    ...others.take(maximumNonPrimary),
  ]);
}

String nextNonPrimarySpeakerLabel(Iterable<SpeakerProfile> profiles) {
  final pattern = RegExp(r'^Speaker (\d+)$');
  var maximum = 1;
  for (final profile in profiles) {
    final match = pattern.firstMatch(profile.label);
    final number = match == null ? null : int.tryParse(match.group(1)!);
    if (number != null && number > maximum) {
      maximum = number;
    }
  }
  return 'Speaker ${maximum + 1}';
}

int _compareSpeakerProfileRetention(SpeakerProfile left, SpeakerProfile right) {
  final updated = right.updatedAt.compareTo(left.updatedAt);
  if (updated != 0) {
    return updated;
  }
  final samples = right.sampleCount.compareTo(left.sampleCount);
  if (samples != 0) {
    return samples;
  }
  return left.id.compareTo(right.id);
}

final class ConversationUtterance {
  const ConversationUtterance({
    required this.id,
    required this.conversationId,
    required this.speakerId,
    required this.speakerLabel,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.confidence,
    required this.updatedAt,
    this.isPrimary = false,
    this.isOverlap = false,
  });

  factory ConversationUtterance.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final conversationId = json['conversationId'];
    final speakerId = json['speakerId'];
    final speakerLabel = json['speakerLabel'];
    final text = json['text'];
    final startMs = json['startMs'];
    final endMs = json['endMs'];
    final confidence = json['confidence'];
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String ||
        conversationId is! String ||
        speakerId is! String ||
        speakerLabel is! String ||
        text is! String ||
        text.trim().isEmpty ||
        startMs is! int ||
        endMs is! int ||
        endMs <= startMs ||
        confidence is! num ||
        updatedAt == null) {
      throw const FormatException('The saved conversation turn is invalid.');
    }
    return ConversationUtterance(
      id: id,
      conversationId: conversationId,
      speakerId: speakerId,
      speakerLabel: speakerLabel,
      text: text.trim(),
      startMs: startMs,
      endMs: endMs,
      confidence: confidence.toDouble().clamp(0, 1),
      updatedAt: updatedAt.toUtc(),
      isPrimary: json['isPrimary'] == true,
      isOverlap: json['isOverlap'] == true,
    );
  }

  final String id;
  final String conversationId;
  final String speakerId;
  final String speakerLabel;
  final String text;
  final int startMs;
  final int endMs;
  final double confidence;
  final DateTime updatedAt;
  final bool isPrimary;
  final bool isOverlap;

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'conversationId': conversationId,
    'speakerId': speakerId,
    'speakerLabel': speakerLabel,
    'text': text,
    'startMs': startMs,
    'endMs': endMs,
    'confidence': confidence,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'isPrimary': isPrimary,
    'isOverlap': isOverlap,
  };
}

final class ConversationRecord {
  const ConversationRecord({
    required this.id,
    required this.audioPath,
    required this.textPath,
    required this.metadataPath,
    required this.utterances,
    required this.updatedAt,
  });

  factory ConversationRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final audioPath = json['audioPath'];
    final textPath = json['textPath'];
    final metadataPath = json['metadataPath'];
    final utterances = json['utterances'];
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String ||
        audioPath is! String ||
        textPath is! String ||
        metadataPath is! String ||
        utterances is! List<Object?> ||
        updatedAt == null) {
      throw const FormatException('The saved conversation record is invalid.');
    }
    return ConversationRecord(
      id: id,
      audioPath: audioPath,
      textPath: textPath,
      metadataPath: metadataPath,
      utterances: utterances
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => ConversationUtterance.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false),
      updatedAt: updatedAt.toUtc(),
    );
  }

  final String id;
  final String audioPath;
  final String textPath;
  final String metadataPath;
  final List<ConversationUtterance> utterances;
  final DateTime updatedAt;

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    'id': id,
    'audioPath': audioPath,
    'textPath': textPath,
    'metadataPath': metadataPath,
    'utterances': utterances
        .map((utterance) => utterance.toJson())
        .toList(growable: false),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

double speakerSimilarity(List<double> left, List<double> right) {
  if (left.isEmpty || left.length != right.length) {
    return -1;
  }
  var dot = 0.0;
  var leftSquare = 0.0;
  var rightSquare = 0.0;
  for (var index = 0; index < left.length; index++) {
    dot += left[index] * right[index];
    leftSquare += left[index] * left[index];
    rightSquare += right[index] * right[index];
  }
  if (leftSquare <= 0 || rightSquare <= 0) {
    return -1;
  }
  return dot / sqrt(leftSquare * rightSquare);
}

double speakerProfileSimilarity(
  SpeakerProfile profile,
  List<double> candidate,
) {
  var best = speakerSimilarity(profile.embedding, candidate);
  for (final signature in profile.signatures) {
    best = max(best, speakerSimilarity(signature, candidate));
  }
  return best;
}

bool isValidSpeakerSignatureThreshold(double threshold) =>
    threshold.isFinite && threshold > 0 && threshold <= 1;

bool speakerSignatureMatches(
  double similarity, {
  double threshold = defaultSpeakerSignatureMatchThreshold,
}) {
  if (!isValidSpeakerSignatureThreshold(threshold)) {
    throw ArgumentError.value(
      threshold,
      'threshold',
      'The signature threshold must be greater than 0 and at most 1.',
    );
  }
  return similarity.isFinite && similarity >= threshold;
}

List<double> normalizeSpeakerEmbedding(List<double> values) {
  var squareSum = 0.0;
  for (final value in values) {
    squareSum += value * value;
  }
  if (squareSum <= 0) {
    return List<double>.from(values, growable: false);
  }
  final magnitude = sqrt(squareSum);
  return values.map((value) => value / magnitude).toList(growable: false);
}
