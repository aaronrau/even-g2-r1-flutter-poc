import 'agent_exchange_store.dart';
import '../protocol/g2_text_layout.dart';

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
  static const int selectorEntryMaximumLines = 2;
  static const int maximumPageCharacters =
      G2TextLayout.historyMaximumPageCharacters;
  static const int maximumDetailRunes = 16384;
  static const int detailBodyLinesPerPage = 9;
  static const int detailPageOverlapLines = 1;
  static const G2TextLayout _layout = G2TextLayout.history;

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
      final message = exchange == null
          ? ''
          : _stripSpeakerPrefix(exchange.message, agent);
      rows.add(
        G2AgentHistoryEntry(
          kind: G2AgentHistoryEntryKind.agent,
          label: agent,
          preview: message.isEmpty ? 'No sent message' : _oneLine(message),
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
    return _truncate(rendered, _layout.maximumPageCharacters);
  }

  String _renderSelector() {
    final pages = _selectorPages();
    final pageIndex = pages.indexWhere((page) => page.contains(selectedIndex));
    final visiblePageIndex = pageIndex < 0 ? 0 : pageIndex;
    final lines = <String>[
      for (final index in pages[visiblePageIndex])
        ..._renderSelectorEntry(index),
    ];
    if (pages.length > 1) {
      lines.add(
        '[ ${visiblePageIndex + 1}/${pages.length} · Swipe to select ]',
      );
    }
    return lines.join('\n');
  }

  List<List<int>> _selectorPages() {
    if (entries.isEmpty) {
      return const <List<int>>[<int>[]];
    }
    final allIndexes = List<int>.generate(entries.length, (index) => index);
    return _layout.paginateBlocks<int>(
      allIndexes,
      rowCount: _selectorEntryLineCount,
      footerRows: 1,
    );
  }

  int _selectorEntryLineCount(int index) {
    final entry = entries[index];
    if (entry.preview.isEmpty) {
      return 1;
    }
    return _layout
        .limitLines(
          '> ${_oneLine(entry.label)} - ${_oneLine(entry.preview)}',
          selectorEntryMaximumLines,
        )
        .length;
  }

  List<String> _renderSelectorEntry(int index) {
    final entry = entries[index];
    final marker = index == selectedIndex ? '>' : ' ';
    if (entry.preview.isEmpty) {
      return <String>['$marker ${_oneLine(entry.label)}'];
    }
    return _layout.limitLines(
      '$marker ${_oneLine(entry.label)} - ${_oneLine(entry.preview)}',
      selectorEntryMaximumLines,
    );
  }

  String _renderDetail({required bool cancel}) {
    final titleLabel = detailTitleIsAgent
        ? '${_speakerLabel(detailTitle ?? 'Unknown')}'
              '${isAgentDetailSpeechTarget ? ' •' : ''}'
        : _oneLine(detailTitle ?? 'History');
    final action = cancel ? 'cancel' : 'dismiss';
    final titleSuffix = ' · Tap to $action ]';
    final titleLabelWidth =
        _layout.wrappingWidthPixels -
        _layout.textWidth('[ ') -
        _layout.textWidth(titleSuffix);
    final title =
        '[ ${_layout.fitLine(titleLabel, titleLabelWidth)}$titleSuffix';
    final pages = _detailPages();
    final pageIndex = detailPageIndex.clamp(0, pages.length - 1);
    final lines = <String>[title, ...pages[pageIndex]];
    while (lines.length < detailBodyLinesPerPage + 1) {
      lines.add('');
    }
    return lines.join('\n');
  }

  List<List<String>> _detailPages() {
    final body = _truncate(_renderDetailBody(), maximumDetailRunes);
    final wrapped = _layout.wrapText(body);
    return _layout.paginateLines(
      wrapped,
      rowsPerPage: detailBodyLinesPerPage,
      overlapRows: detailPageOverlapLines,
    );
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
      final speaker = _speakerLabel(exchange.agent);
      final message = _stripSpeakerPrefix(exchange.message, exchange.agent);
      final response = exchange.response == null
          ? null
          : _stripSpeakerPrefix(exchange.response!, exchange.agent);
      sections.add(
        '${index == 0 ? 'Latest conversation' : 'Earlier conversation ${index + 1}'}\n'
        'You: ${message.isEmpty ? 'No saved message' : message}\n'
        '$speaker ${response == null || response.isEmpty ? 'No response yet' : response}',
      );
    }
    return sections.join('\n\n');
  }

  void _clearDetailSpeech() {
    detailSpeechSegmentId = null;
    detailSpeechTranscript = null;
    detailSpeechState = null;
  }

  static String _oneLine(String value) => _layout.oneLine(value);

  static String _speakerLabel(String value) {
    final name = _oneLine(value).replaceFirst(RegExp(r':+$'), '');
    return '${name.isEmpty ? 'Unknown' : name}:';
  }

  static String _stripSpeakerPrefix(String value, String speaker) {
    final trimmed = value.trim();
    final name = _oneLine(speaker).replaceFirst(RegExp(r':+$'), '');
    if (name.isEmpty) {
      return trimmed;
    }
    return trimmed
        .replaceFirst(
          RegExp('^${RegExp.escape(name)}\\s*:\\s*', caseSensitive: false),
          '',
        )
        .trimLeft();
  }

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
