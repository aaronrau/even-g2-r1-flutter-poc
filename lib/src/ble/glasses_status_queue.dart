import 'dart:async';

typedef GlassesStatusLog = void Function(String message, {bool isError});

enum GlassesTranscriptOutcome { saved, sent }

/// A latest-wins status channel for the small G2 display.
///
/// Durable transcripts and messages are stored before they reach this class.
/// The glasses are only a live projection, so retaining a FIFO of stale text
/// wastes memory and can let an old clear overwrite newer content.
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

  final bool Function() _isConnected;
  final Future<void> Function(String message) _showText;
  final Future<void> Function() _clearText;
  final GlassesStatusLog _log;
  final Duration _terminalDisplayDuration;

  _GlassesStatusEntry? _current;
  _GlassesStatusEntry? _deferredTransient;
  String? _latestTranscriptId;
  bool _pumping = false;
  bool _pumpRequested = false;
  bool _disposed = false;
  int _revision = 0;
  int _transientSequence = 0;
  Timer? _holdTimer;
  Completer<void>? _holdCompleter;

  int get pendingCount =>
      (_current == null ? 0 : 1) + (_deferredTransient == null ? 0 : 1);

  Future<void> queueTranscript({
    required String segmentId,
    required String transcript,
  }) async {
    if (_disposed) {
      return;
    }
    _latestTranscriptId = segmentId;
    _deferredTransient = null;
    final current = _current;
    if (current?.isTransient == false && current?.id == segmentId) {
      return;
    }
    _replaceCurrent(
      _GlassesStatusEntry.transcript(id: segmentId, text: transcript),
    );
    _log('[WorkBench][GlassesStatus] state=queued pending=1');
  }

  Future<void> completeTranscript({
    required String segmentId,
    required String transcript,
    required GlassesTranscriptOutcome outcome,
  }) async {
    if (_disposed) {
      return;
    }
    var current = _current;
    if ((current == null || current.isTransient) &&
        _latestTranscriptId == segmentId) {
      _replaceCurrent(
        _GlassesStatusEntry.completedTranscript(
          id: segmentId,
          text: transcript,
          outcome: outcome,
        ),
      );
      current = _current;
    }
    if (current == null || current.isTransient || current.id != segmentId) {
      _log(
        '[WorkBench][GlassesStatus] state=completion_superseded '
        'outcome=${outcome.name}',
      );
      return;
    }
    current
      ..text = transcript
      ..outcome = outcome;
    _revision++;
    _cancelHold();
    _log('[WorkBench][GlassesStatus] state=${outcome.name} pending=1');
    _startPump();
  }

  Future<void> queueTransient({
    required String prefix,
    required String message,
  }) async {
    if (_disposed) {
      return;
    }
    _transientSequence++;
    final entry = _GlassesStatusEntry.transient(
      id: 'transient-$_transientSequence',
      initialPrefix: prefix,
      text: message,
    );
    final current = _current;
    if (current != null && !current.isTransient && current.outcome != null) {
      _deferredTransient = entry;
      _log('[WorkBench][GlassesStatus] state=received_deferred pending=2');
      return;
    }
    _replaceCurrent(entry);
    _log('[WorkBench][GlassesStatus] state=received_queued pending=1');
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
    _cancelHold();
    _current = null;
    _deferredTransient = null;
    _latestTranscriptId = null;
  }

  void _replaceCurrent(_GlassesStatusEntry entry) {
    final superseded = _current;
    _current = entry;
    _revision++;
    _cancelHold();
    if (superseded != null) {
      _log('[WorkBench][GlassesStatus] state=superseded pending=1');
    }
    _startPump();
  }

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
      while (!_disposed) {
        final entry = _current;
        if (entry == null || !_isConnected()) {
          return;
        }
        final revision = _revision;

        if (!entry.initialShown) {
          final shown = await _tryShow(
            _format(entry.initialPrefix, entry.text),
          );
          if (!shown || _disposed) {
            return;
          }
          if (!_isCurrent(entry, revision)) {
            continue;
          }
          entry.initialShown = true;
          if (entry.isTransient) {
            _log(
              '[WorkBench][GlassesStatus] state=received_displayed pending=1',
            );
            await _waitForTerminalDisplay();
            if (_disposed) {
              return;
            }
            if (!_isCurrent(entry, revision)) {
              continue;
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
          final finalRevision = _revision;
          final shown = await _tryShow(
            _format(_outcomePrefix(outcome), entry.text),
          );
          if (!shown || _disposed) {
            return;
          }
          if (!_isCurrent(entry, finalRevision)) {
            continue;
          }
          entry.finalShown = true;
          await _waitForTerminalDisplay();
          if (_disposed) {
            return;
          }
          if (!_isCurrent(entry, finalRevision)) {
            continue;
          }
          entry.readyToClear = true;
        }

        if (!entry.readyToClear || !_isConnected()) {
          return;
        }
        final clearRevision = _revision;
        final cleared = await _tryClear();
        if (!cleared || _disposed) {
          return;
        }
        if (!_isCurrent(entry, clearRevision)) {
          continue;
        }
        _current = null;
        if (!entry.isTransient && _latestTranscriptId == entry.id) {
          _latestTranscriptId = null;
        }
        _revision++;
        _log('[WorkBench][GlassesStatus] state=cleared pending=0');
        final deferred = _deferredTransient;
        if (deferred != null) {
          _deferredTransient = null;
          _current = deferred;
          _revision++;
          _log(
            '[WorkBench][GlassesStatus] '
            'state=received_queued pending=1',
          );
        }
      }
    } finally {
      _pumping = false;
      if (_pumpRequested && !_disposed) {
        _pumpRequested = false;
        _startPump();
      }
    }
  }

  bool _isCurrent(_GlassesStatusEntry entry, int revision) =>
      identical(_current, entry) && _revision == revision;

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
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    final completer = _holdCompleter;
    _holdCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
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

  _GlassesStatusEntry.completedTranscript({
    required this.id,
    required this.text,
    required this.outcome,
  }) : initialPrefix = 'Queued',
       isTransient = false,
       initialShown = true;

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
