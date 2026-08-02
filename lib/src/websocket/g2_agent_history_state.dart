import 'agent_exchange_store.dart';

enum G2AgentHistoryMode { closed, selector, waiting, detail }

enum G2AgentHistoryEntryKind { dismiss, memo, agent }

enum G2AgentDetailSpeechState { listening, sending, sent, saved }

final class G2AgentHistoryEntry {
  const G2AgentHistoryEntry({
    required this.kind,
    required this.label,
    required this.preview,
    this.exchange,
    this.detail,
  });

  final G2AgentHistoryEntryKind kind;
  final String label;
  final String preview;
  final AgentExchangeView? exchange;
  final String? detail;
}

final class G2AgentHistoryState {
  static const int maximumAgents = 5;
  static const int maximumAgentConversations = 5;
  static const int maximumRowRunes = 48;
  static const int maximumPageCharacters = 512;
  static const int maximumDetailRunes = 16384;
  static const int detailLineRunes = 45;
  static const int detailBodyLinesPerPage = 8;

  G2AgentHistoryMode mode = G2AgentHistoryMode.closed;
  List<G2AgentHistoryEntry> entries = const <G2AgentHistoryEntry>[];
  int selectedIndex = 0;
  String? waitingExchangeId;
  String? detailTitle;
  String? detailText;
  bool detailTitleIsAgent = false;
  int detailPageIndex = 0;
  bool waitingTimedOut = false;
  String? detailSpeechSegmentId;
  String? detailSpeechTranscript;
  G2AgentDetailSpeechState? detailSpeechState;

  bool get isOpen => mode != G2AgentHistoryMode.closed;
  G2AgentHistoryEntry? get selected =>
      entries.isEmpty ? null : entries[selectedIndex];
  bool get isAgentDetailSpeechTarget =>
      detailTitleIsAgent &&
      (mode == G2AgentHistoryMode.detail || mode == G2AgentHistoryMode.waiting);
  String? get selectedSpeechAgent {
    final entry = selected;
    if (mode == G2AgentHistoryMode.selector &&
        entry != null &&
        entry.kind == G2AgentHistoryEntryKind.agent) {
      return entry.label;
    }
    if (isAgentDetailSpeechTarget) {
      final title = detailTitle?.trim();
      return title == null || title.isEmpty ? null : title;
    }
    return null;
  }

  String? get activeDetailSpeechSegmentId => switch (detailSpeechState) {
    G2AgentDetailSpeechState.listening ||
    G2AgentDetailSpeechState.sending => detailSpeechSegmentId,
    _ => null,
  };

  int get detailPageCount => _detailPages().length;

  void open({
    required List<String> agents,
    required List<AgentExchangeView> exchanges,
    String? memo,
  }) {
    final byAgent = <String, AgentExchangeView>{
      for (final exchange in exchanges) exchange.agent.toLowerCase(): exchange,
    };
    final configuredAgents = agents
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final recent = exchanges.toList(growable: false)
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    final chosenAgents = <String>{
      ...recent.take(maximumAgents).map((exchange) => exchange.agent),
    };
    for (final agent in configuredAgents) {
      if (chosenAgents.length >= maximumAgents) {
        break;
      }
      chosenAgents.add(agent);
    }
    final rows = <G2AgentHistoryEntry>[
      const G2AgentHistoryEntry(
        kind: G2AgentHistoryEntryKind.dismiss,
        label: '[x]',
        preview: '',
      ),
    ];
    for (final agent in configuredAgents.where(chosenAgents.contains)) {
      final exchange = byAgent[agent.toLowerCase()];
      rows.add(
        G2AgentHistoryEntry(
          kind: G2AgentHistoryEntryKind.agent,
          label: agent,
          preview: exchange == null || _oneLine(exchange.message).isEmpty
              ? 'No sent message'
              : _oneLine(exchange.message),
          exchange: exchange,
        ),
      );
    }
    rows.add(
      G2AgentHistoryEntry(
        kind: G2AgentHistoryEntryKind.memo,
        label: 'Memo',
        preview: _oneLine(memo ?? '').isEmpty
            ? 'No saved memo'
            : _oneLine(memo!),
        detail: _oneLine(memo ?? '').isEmpty ? null : memo!.trim(),
      ),
    );
    entries = List<G2AgentHistoryEntry>.unmodifiable(rows);
    selectedIndex = 0;
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailTitleIsAgent = false;
    detailPageIndex = 0;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.selector;
  }

  void selectNext() {
    if (mode != G2AgentHistoryMode.selector || entries.isEmpty) {
      return;
    }
    selectedIndex = (selectedIndex + 1) % entries.length;
  }

  void selectPrevious() {
    if (mode != G2AgentHistoryMode.selector || entries.isEmpty) {
      return;
    }
    selectedIndex = (selectedIndex - 1 + entries.length) % entries.length;
  }

  void showSelectedDetail() {
    final entry = selected;
    if (entry == null) {
      return;
    }
    detailTitle = entry.label;
    detailTitleIsAgent = entry.kind == G2AgentHistoryEntryKind.agent;
    detailText = switch (entry.kind) {
      G2AgentHistoryEntryKind.dismiss => '',
      G2AgentHistoryEntryKind.memo =>
        entry.detail?.trim().isNotEmpty == true
            ? entry.detail
            : 'No saved memo',
      G2AgentHistoryEntryKind.agent => _renderAgentConversations(
        entry.exchange == null
            ? const <AgentExchangeView>[]
            : <AgentExchangeView>[entry.exchange!],
      ),
    };
    detailPageIndex = 0;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.detail;
  }

  void showAgentConversations(List<AgentExchangeView> exchanges) {
    final entry = selected;
    if (entry == null || entry.kind != G2AgentHistoryEntryKind.agent) {
      return;
    }
    final recent =
        exchanges
            .where(
              (exchange) =>
                  exchange.agent.trim().toLowerCase() ==
                  entry.label.trim().toLowerCase(),
            )
            .toList(growable: false)
          ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    detailTitle = entry.label;
    detailTitleIsAgent = true;
    detailText = _renderAgentConversations(
      recent.take(maximumAgentConversations).toList(growable: false),
    );
    detailPageIndex = 0;
    waitingExchangeId = null;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.detail;
  }

  void showWaiting(AgentExchangeView exchange) {
    waitingExchangeId = exchange.id;
    detailTitle = exchange.agent;
    detailTitleIsAgent = true;
    detailText = 'Waiting for response…';
    detailPageIndex = 0;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.waiting;
  }

  bool acceptResponse(String exchangeId, String response) {
    if (mode != G2AgentHistoryMode.waiting || waitingExchangeId != exchangeId) {
      return false;
    }
    detailText = response.trim().isEmpty
        ? 'Response received'
        : response.trim();
    detailPageIndex = 0;
    waitingExchangeId = null;
    waitingTimedOut = false;
    mode = G2AgentHistoryMode.detail;
    return true;
  }

  void markWaitingTimedOut() {
    if (mode != G2AgentHistoryMode.waiting) {
      return;
    }
    waitingTimedOut = true;
    detailText = 'Still waiting';
  }

  void showError(String title, String message) {
    waitingExchangeId = null;
    detailTitle = title;
    detailTitleIsAgent = true;
    detailText = message;
    detailPageIndex = 0;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.detail;
  }

  bool beginTargetedSpeech(String segmentId) {
    if (!isAgentDetailSpeechTarget) {
      return false;
    }
    detailSpeechSegmentId = segmentId;
    detailSpeechTranscript = null;
    detailSpeechState = G2AgentDetailSpeechState.listening;
    detailPageIndex = 0;
    return true;
  }

  bool showTargetedSpeechTranscript({
    required String segmentId,
    required String transcript,
  }) {
    if (!isAgentDetailSpeechTarget || detailSpeechSegmentId != segmentId) {
      return false;
    }
    detailSpeechTranscript = transcript.trim();
    detailSpeechState = G2AgentDetailSpeechState.sending;
    detailPageIndex = 0;
    return true;
  }

  bool completeTargetedSpeech({
    required String segmentId,
    required String transcript,
    required bool sent,
  }) {
    if (!isAgentDetailSpeechTarget || detailSpeechSegmentId != segmentId) {
      return false;
    }
    detailSpeechTranscript = transcript.trim();
    detailSpeechState = sent
        ? G2AgentDetailSpeechState.sent
        : G2AgentDetailSpeechState.saved;
    detailPageIndex = 0;
    return true;
  }

  void close() {
    mode = G2AgentHistoryMode.closed;
    entries = const <G2AgentHistoryEntry>[];
    selectedIndex = 0;
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailTitleIsAgent = false;
    detailPageIndex = 0;
    waitingTimedOut = false;
    _clearDetailSpeech();
  }

  bool selectPreviousDetailPage() {
    if (mode != G2AgentHistoryMode.detail || detailPageIndex <= 0) {
      return false;
    }
    detailPageIndex--;
    return true;
  }

  bool selectNextDetailPage() {
    if (mode != G2AgentHistoryMode.detail ||
        detailPageIndex >= detailPageCount - 1) {
      return false;
    }
    detailPageIndex++;
    return true;
  }

  String render() {
    final rendered = switch (mode) {
      G2AgentHistoryMode.closed => '',
      G2AgentHistoryMode.selector => _renderSelector(),
      G2AgentHistoryMode.waiting => _renderDetail(cancel: true),
      G2AgentHistoryMode.detail => _renderDetail(cancel: false),
    };
    return _truncate(rendered, maximumPageCharacters);
  }

  String _renderSelector() {
    final lines = <String>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final marker = index == selectedIndex ? '>' : ' ';
      final content = entry.preview.isEmpty
          ? entry.label
          : '${entry.label} · ${entry.preview}';
      lines.add('$marker ${_truncate(_oneLine(content), maximumRowRunes - 2)}');
    }
    return lines.join('\n');
  }

  String _renderDetail({required bool cancel}) {
    final titleLabel = detailTitleIsAgent
        ? 'Agent: ${_oneLine(detailTitle ?? 'Unknown')}'
              '${isAgentDetailSpeechTarget ? ' •' : ''}'
        : _oneLine(detailTitle ?? 'History');
    final title = '[ ${_truncate(titleLabel, detailLineRunes - 4)} ]';
    final pages = _detailPages();
    final pageIndex = detailPageIndex.clamp(0, pages.length - 1);
    final lines = <String>[title, ...pages[pageIndex]];
    while (lines.length < detailBodyLinesPerPage + 1) {
      lines.add('');
    }
    final action = cancel ? 'cancel' : 'dismiss';
    lines.add(
      pages.length == 1
          ? '[ Tap to $action ]'
          : '[ ${pageIndex + 1}/${pages.length} · Tap to $action ]',
    );
    return lines.join('\n');
  }

  List<List<String>> _detailPages() {
    final body = _truncate(_renderDetailBody(), maximumDetailRunes);
    final wrapped = _wrapDetailLines(body);
    final pages = <List<String>>[];
    for (
      var start = 0;
      start < wrapped.length;
      start += detailBodyLinesPerPage
    ) {
      final end = (start + detailBodyLinesPerPage).clamp(0, wrapped.length);
      pages.add(wrapped.sublist(start, end));
    }
    return pages.isEmpty
        ? const <List<String>>[
            <String>[''],
          ]
        : pages;
  }

  String _renderDetailBody() {
    final speechState = detailSpeechState;
    if (speechState == null) {
      return (detailText ?? '').trim();
    }
    final transcript = (detailSpeechTranscript ?? '').trim();
    return switch (speechState) {
      G2AgentDetailSpeechState.listening => 'Listening…',
      G2AgentDetailSpeechState.sending =>
        transcript.isEmpty ? 'Sending…' : 'Sending: $transcript',
      G2AgentDetailSpeechState.sent =>
        transcript.isEmpty ? 'Sent' : 'Sent: $transcript',
      G2AgentDetailSpeechState.saved =>
        transcript.isEmpty ? 'Saved' : 'Saved: $transcript',
    };
  }

  static String _renderAgentConversations(List<AgentExchangeView> exchanges) {
    if (exchanges.isEmpty) {
      return 'No conversation yet';
    }
    final sections = <String>[];
    for (var index = 0; index < exchanges.length; index++) {
      final exchange = exchanges[index];
      final message = exchange.message.trim();
      final response = exchange.response?.trim();
      sections.add(
        '${index == 0 ? 'Latest conversation' : 'Earlier conversation ${index + 1}'}\n'
        'You: ${message.isEmpty ? 'No saved message' : message}\n'
        'Agent: ${response == null || response.isEmpty ? 'No response yet' : response}',
      );
    }
    return sections.join('\n\n');
  }

  void _clearDetailSpeech() {
    detailSpeechSegmentId = null;
    detailSpeechTranscript = null;
    detailSpeechState = null;
  }

  static List<String> _wrapDetailLines(String value) {
    final lines = <String>[];
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final sourceLine in normalized.split('\n')) {
      final paragraph = sourceLine
          .replaceAll(RegExp(r'[\t\f\v ]+'), ' ')
          .trim();
      if (paragraph.isEmpty) {
        lines.add('');
        continue;
      }
      lines.addAll(_wrapDetailParagraph(paragraph));
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  static List<String> _wrapDetailParagraph(String value) {
    final words = value.split(' ').where((word) => word.isNotEmpty);
    final lines = <String>[];
    var line = '';
    for (final sourceWord in words) {
      var remaining = sourceWord;
      while (remaining.runes.length > detailLineRunes) {
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        final runes = remaining.runes.toList(growable: false);
        lines.add(String.fromCharCodes(runes.take(detailLineRunes)));
        remaining = String.fromCharCodes(runes.skip(detailLineRunes));
      }
      if (remaining.isEmpty) {
        continue;
      }
      final candidate = line.isEmpty ? remaining : '$line $remaining';
      if (candidate.runes.length <= detailLineRunes) {
        line = candidate;
      } else {
        lines.add(line);
        line = remaining;
      }
    }
    if (line.isNotEmpty) {
      lines.add(line);
    }
    return lines;
  }

  static String _oneLine(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _truncate(String value, int maximumRunes) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= maximumRunes) {
      return value;
    }
    if (maximumRunes <= 1) {
      return '…';
    }
    return '${String.fromCharCodes(runes.take(maximumRunes - 1))}…';
  }
}
