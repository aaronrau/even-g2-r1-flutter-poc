import 'dart:async';
import 'dart:collection';

typedef GlassesStatusLog = void Function(String message, {bool isError});

enum GlassesTranscriptOutcome { saved, sent }

final class GlassesStatusQueue {
  GlassesStatusQueue({
    required bool Function() isConnected,
    required Future<void> Function(String message) showText,
    required Future<void> Function() clearText,
    required GlassesStatusLog log,
    Duration terminalDisplayDuration = const Duration(seconds: 2),
  }) : _isConnected = isConnected,
       _showText = showText,
       _clearText = clearText,
       _log = log,
       _terminalDisplayDuration = terminalDisplayDuration;

  static const int maximumMessageCharacters = 512;
  static const int _maximumPendingEntries = 64;

  final bool Function() _isConnected;
  final Future<void> Function(String message) _showText;
  final Future<void> Function() _clearText;
  final GlassesStatusLog _log;
  final Duration _terminalDisplayDuration;
  final Queue<_GlassesStatusEntry> _entries = Queue<_GlassesStatusEntry>();
  final Map<String, _GlassesStatusEntry> _transcripts =
      <String, _GlassesStatusEntry>{};

  bool _pumping = false;
  bool _pumpRequested = false;
  bool _disposed = false;
  int _transientSequence = 0;
  Timer? _holdTimer;
  Completer<void>? _holdCompleter;

  int get pendingCount => _entries.length;

  Future<void> queueTranscript({
    required String segmentId,
    required String transcript,
  }) async {
    if (_disposed || _transcripts.containsKey(segmentId)) {
      return;
    }
    if (!_hasCapacity()) {
      _log(
        '[WorkBench][GlassesStatus] state=queue_full '
        'pending=${_entries.length}',
        isError: true,
      );
      return;
    }
    final entry = _GlassesStatusEntry.transcript(
      id: segmentId,
      text: transcript,
    );
    _entries.add(entry);
    _transcripts[segmentId] = entry;
    _log(
      '[WorkBench][GlassesStatus] state=queued '
      'pending=${_entries.length}',
    );
    _startPump();
  }

  Future<void> completeTranscript({
    required String segmentId,
    required String transcript,
    required GlassesTranscriptOutcome outcome,
  }) async {
    if (_disposed) {
      return;
    }
    final entry = _transcripts[segmentId];
    if (entry == null) {
      _log(
        '[WorkBench][GlassesStatus] state=completion_missing '
        'outcome=${outcome.name}',
        isError: true,
      );
      return;
    }
    entry
      ..text = transcript
      ..outcome = outcome;
    _log(
      '[WorkBench][GlassesStatus] state=${outcome.name} '
      'pending=${_entries.length}',
    );
    _startPump();
  }

  Future<void> queueTransient({
    required String prefix,
    required String message,
  }) async {
    if (_disposed) {
      return;
    }
    if (!_hasCapacity()) {
      _log(
        '[WorkBench][GlassesStatus] state=queue_full '
        'pending=${_entries.length}',
        isError: true,
      );
      return;
    }
    _transientSequence++;
    _entries.add(
      _GlassesStatusEntry.transient(
        id: 'transient-$_transientSequence',
        initialPrefix: prefix,
        text: message,
      ),
    );
    _startPump();
  }

  void connectionChanged() {
    if (!_disposed && _isConnected()) {
      _startPump();
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    final completer = _holdCompleter;
    _holdCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _entries.clear();
    _transcripts.clear();
  }

  bool _hasCapacity() => _entries.length < _maximumPendingEntries;

  void _startPump() {
    if (_disposed) {
      return;
    }
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_disposed || _pumping) {
      return;
    }
    _pumping = true;
    try {
      while (!_disposed && _entries.isNotEmpty) {
        if (!_isConnected()) {
          return;
        }
        final entry = _entries.first;
        if (!entry.initialShown) {
          final shown = await _tryShow(
            _format(entry.initialPrefix, entry.text),
          );
          if (!shown || _disposed) {
            return;
          }
          entry.initialShown = true;
          if (entry.isTransient) {
            await _waitForTerminalDisplay();
            if (_disposed) {
              return;
            }
            entry.readyToClear = true;
          }
        }

        if (!entry.isTransient && !entry.finalShown) {
          final outcome = entry.outcome;
          if (outcome == null) {
            return;
          }
          if (!_isConnected()) {
            return;
          }
          final shown = await _tryShow(
            _format(_outcomePrefix(outcome), entry.text),
          );
          if (!shown || _disposed) {
            return;
          }
          entry.finalShown = true;
          await _waitForTerminalDisplay();
          if (_disposed) {
            return;
          }
          entry.readyToClear = true;
        }

        if (!entry.readyToClear || !_isConnected()) {
          return;
        }
        final cleared = await _tryClear();
        if (!cleared || _disposed) {
          return;
        }
        _entries.removeFirst();
        if (!entry.isTransient) {
          _transcripts.remove(entry.id);
        }
        _log(
          '[WorkBench][GlassesStatus] state=cleared '
          'pending=${_entries.length}',
        );
      }
    } finally {
      _pumping = false;
      if (_pumpRequested && !_disposed) {
        _pumpRequested = false;
        _startPump();
      }
    }
  }

  Future<bool> _tryShow(String message) async {
    try {
      await _showText(message);
      return true;
    } on Object catch (error) {
      _log(
        '[WorkBench][GlassesStatus] state=display_failed '
        'error=${_oneLine(error)}',
        isError: true,
      );
      return false;
    }
  }

  Future<bool> _tryClear() async {
    try {
      await _clearText();
      return true;
    } on Object catch (error) {
      _log(
        '[WorkBench][GlassesStatus] state=clear_failed '
        'error=${_oneLine(error)}',
        isError: true,
      );
      return false;
    }
  }

  Future<void> _waitForTerminalDisplay() {
    final completer = Completer<void>();
    _holdCompleter = completer;
    _holdTimer = Timer(_terminalDisplayDuration, () {
      if (identical(_holdCompleter, completer)) {
        _holdCompleter = null;
        _holdTimer = null;
      }
      completer.complete();
    });
    return completer.future;
  }

  static String _outcomePrefix(GlassesTranscriptOutcome outcome) =>
      switch (outcome) {
        GlassesTranscriptOutcome.saved => 'Saved',
        GlassesTranscriptOutcome.sent => 'Sent',
      };

  static String _format(String prefix, String value) {
    final normalized = value
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final available = maximumMessageCharacters - prefix.length - 2;
    final content = normalized.length <= available
        ? normalized
        : '${normalized.substring(0, available - 1)}…';
    return '$prefix: $content';
  }

  static String _oneLine(Object error) =>
      error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

final class _GlassesStatusEntry {
  _GlassesStatusEntry.transcript({required this.id, required this.text})
    : initialPrefix = 'Queued',
      isTransient = false;

  _GlassesStatusEntry.transient({
    required this.id,
    required this.initialPrefix,
    required this.text,
  }) : isTransient = true;

  final String id;
  final String initialPrefix;
  final bool isTransient;
  String text;
  GlassesTranscriptOutcome? outcome;
  bool initialShown = false;
  bool finalShown = false;
  bool readyToClear = false;
}
