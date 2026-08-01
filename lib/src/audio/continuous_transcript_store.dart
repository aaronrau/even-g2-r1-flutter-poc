import 'dart:io';

import 'transcription_chunking.dart';

final class ContinuousTranscriptSnapshot {
  const ContinuousTranscriptSnapshot({
    required this.path,
    required this.text,
    required this.appendedText,
  });

  final String path;
  final String text;
  final String appendedText;
}

/// Maintains one durable raw-text view for all forced STT chunks that belong
/// to the same uninterrupted VAD conversation.
final class ContinuousTranscriptStore {
  const ContinuousTranscriptStore({required this.speechPath});

  final String speechPath;

  Future<ContinuousTranscriptSnapshot> append({
    required String conversationId,
    required String text,
    bool deduplicateOverlap = false,
  }) async {
    final safeId = _safeConversationId(conversationId);
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final target = File('$speechPath/$safeId.continuous.txt');
    final existing = await target.exists()
        ? (await target.readAsString()).trim()
        : '';
    final appended = deduplicateOverlap
        ? removeTranscriptionOverlap(previous: existing, incoming: normalized)
        : normalized;
    final combined = <String>[
      if (existing.isNotEmpty) existing,
      if (appended.isNotEmpty) appended,
    ].join('\n');
    final partial = File('${target.path}.part');
    await partial.writeAsString(
      combined.isEmpty ? '' : '$combined\n',
      flush: true,
    );
    // Android uses POSIX rename semantics, so readers see the prior complete
    // transcript or the newly appended complete transcript, never a partial.
    await partial.rename(target.path);
    return ContinuousTranscriptSnapshot(
      path: target.path,
      text: combined,
      appendedText: appended,
    );
  }

  static String _safeConversationId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw const FormatException('The conversation ID is invalid.');
    }
    return safe;
  }
}
