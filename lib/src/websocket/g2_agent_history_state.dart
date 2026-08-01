import 'agent_exchange_store.dart';

enum G2AgentHistoryMode { closed, selector, waiting, detail }

enum G2AgentHistoryEntryKind { dismiss, memo, agent }

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
  static const int maximumRowRunes = 48;
  static const int maximumPageCharacters = 512;
  static const int maximumDetailRunes = 4096;
  static const int detailLineRunes = 48;
  static const int detailBodyLinesPerPage = 7;

  G2AgentHistoryMode mode = G2AgentHistoryMode.closed;
  List<G2AgentHistoryEntry> entries = const <G2AgentHistoryEntry>[];
  int selectedIndex = 0;
  String? waitingExchangeId;
  String? detailTitle;
  String? detailText;
  int detailPageIndex = 0;
  bool waitingTimedOut = false;

  bool get isOpen => mode != G2AgentHistoryMode.closed;
  G2AgentHistoryEntry? get selected =>
      entries.isEmpty ? null : entries[selectedIndex];
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
        label: 'Dismiss',
        preview: '',
      ),
      G2AgentHistoryEntry(
        kind: G2AgentHistoryEntryKind.memo,
        label: 'Memo',
        preview: _oneLine(memo ?? '').isEmpty
            ? 'No saved memo'
            : _oneLine(memo!),
        detail: _oneLine(memo ?? '').isEmpty ? null : memo!.trim(),
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
    entries = List<G2AgentHistoryEntry>.unmodifiable(rows);
    selectedIndex = 0;
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailPageIndex = 0;
    waitingTimedOut = false;
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
    detailText = switch (entry.kind) {
      G2AgentHistoryEntryKind.dismiss => '',
      G2AgentHistoryEntryKind.memo =>
        entry.detail?.trim().isNotEmpty == true
            ? entry.detail
            : 'No saved memo',
      G2AgentHistoryEntryKind.agent =>
        entry.exchange == null ? 'No sent message' : entry.exchange!.response,
    };
    detailPageIndex = 0;
    mode = G2AgentHistoryMode.detail;
  }

  void showWaiting(AgentExchangeView exchange) {
    waitingExchangeId = exchange.id;
    detailTitle = exchange.agent;
    detailText = 'Waiting for response…';
    detailPageIndex = 0;
    waitingTimedOut = false;
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
    detailText = message;
    detailPageIndex = 0;
    waitingTimedOut = false;
    mode = G2AgentHistoryMode.detail;
  }

  void close() {
    mode = G2AgentHistoryMode.closed;
    entries = const <G2AgentHistoryEntry>[];
    selectedIndex = 0;
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailPageIndex = 0;
    waitingTimedOut = false;
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
    final title = _truncate(
      _oneLine(detailTitle ?? 'History'),
      detailLineRunes,
    );
    final pages = _detailPages();
    final pageIndex = detailPageIndex.clamp(0, pages.length - 1);
    final lines = <String>[title, ...pages[pageIndex]];
    while (lines.length < detailBodyLinesPerPage + 1) {
      lines.add('');
    }
    lines.add('');
    final action = cancel ? 'cancel' : 'dismiss';
    lines.add(
      pages.length == 1
          ? '[ Tap to $action ]'
          : '[ ${pageIndex + 1}/${pages.length} · Tap to $action ]',
    );
    return lines.join('\n');
  }

  List<List<String>> _detailPages() {
    final body = _truncate((detailText ?? '').trim(), maximumDetailRunes);
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

  static List<String> _wrapDetailLines(String value) {
    final words = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
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
