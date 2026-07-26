final class TranscriptTurnState {
  String? _currentSegmentId;
  String? _visibleText;

  String? get currentSegmentId => _currentSegmentId;
  String? get visibleText => _visibleText;

  void startTurn(String segmentId) {
    _currentSegmentId = segmentId;
    _visibleText = null;
  }

  bool completeTurn(String segmentId, String text) {
    if (segmentId != _currentSegmentId) {
      return false;
    }
    final normalized = text.trim();
    _visibleText = normalized.isEmpty ? null : normalized;
    return true;
  }

  void endSession() {
    _currentSegmentId = null;
    _visibleText = null;
  }
}
