import 'dart:math';

const Duration maximumTranscriptionWindow = Duration(seconds: 18);
const Duration transcriptionWindowOverlap = Duration(milliseconds: 500);

final class TranscriptionSampleWindow {
  const TranscriptionSampleWindow({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start;
}

List<TranscriptionSampleWindow> planTranscriptionWindows({
  required int totalSamples,
  required int sampleRate,
}) {
  if (totalSamples <= 0 || sampleRate <= 0) {
    return const <TranscriptionSampleWindow>[];
  }
  final maximumSamples =
      sampleRate *
      maximumTranscriptionWindow.inMilliseconds ~/
      Duration.millisecondsPerSecond;
  final overlapSamples =
      sampleRate *
      transcriptionWindowOverlap.inMilliseconds ~/
      Duration.millisecondsPerSecond;
  final windows = <TranscriptionSampleWindow>[];
  var start = 0;
  while (start < totalSamples) {
    final end = min(totalSamples, start + maximumSamples);
    windows.add(TranscriptionSampleWindow(start: start, end: end));
    if (end == totalSamples) {
      break;
    }
    start = end - overlapSamples;
  }
  return windows;
}

String mergeTranscriptionWindows(Iterable<String> transcripts) {
  var merged = '';
  for (final transcript in transcripts) {
    final unique = removeTranscriptionOverlap(
      previous: merged,
      incoming: transcript,
    );
    if (unique.isEmpty) {
      continue;
    }
    merged = <String>[if (merged.isNotEmpty) merged, unique].join(' ');
  }
  return merged.trim();
}

/// Removes the exact word sequence repeated by two overlapping audio windows.
///
/// Only a suffix of [previous] that exactly matches a prefix of [incoming] is
/// removed, so unmatched words on either side of the capture boundary remain.
String removeTranscriptionOverlap({
  required String previous,
  required String incoming,
  int maximumWords = 20,
}) {
  assert(maximumWords > 0);
  final previousWords = _words(previous);
  final incomingWords = _words(incoming);
  if (incomingWords.isEmpty || previousWords.isEmpty) {
    return incomingWords.join(' ');
  }
  var overlap = 0;
  final maximumOverlap = min(
    maximumWords,
    min(previousWords.length, incomingWords.length),
  );
  for (var candidate = maximumOverlap; candidate > 0; candidate--) {
    var matches = true;
    for (var offset = 0; offset < candidate; offset++) {
      final prior = previousWords[previousWords.length - candidate + offset];
      if (_normalizeWord(prior) != _normalizeWord(incomingWords[offset])) {
        matches = false;
        break;
      }
    }
    if (matches) {
      overlap = candidate;
      break;
    }
  }
  return incomingWords.skip(overlap).join(' ').trim();
}

List<String> _words(String value) => value
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .toList(growable: false);

String _normalizeWord(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'^[^a-z0-9]+|[^a-z0-9]+$'), '');
