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
  final merged = <String>[];
  for (final transcript in transcripts) {
    final incoming = transcript
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (incoming.isEmpty) {
      continue;
    }
    var overlap = 0;
    final maximumOverlap = min(20, min(merged.length, incoming.length));
    for (var candidate = maximumOverlap; candidate > 0; candidate--) {
      var matches = true;
      for (var offset = 0; offset < candidate; offset++) {
        final previous = merged[merged.length - candidate + offset];
        if (_normalizeWord(previous) != _normalizeWord(incoming[offset])) {
          matches = false;
          break;
        }
      }
      if (matches) {
        overlap = candidate;
        break;
      }
    }
    merged.addAll(incoming.skip(overlap));
  }
  return merged.join(' ').trim();
}

String _normalizeWord(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'^[^a-z0-9]+|[^a-z0-9]+$'), '');
