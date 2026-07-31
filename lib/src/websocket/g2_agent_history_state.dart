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

  G2AgentHistoryMode mode = G2AgentHistoryMode.closed;
  List<G2AgentHistoryEntry> entries = const <G2AgentHistoryEntry>[];
  int selectedIndex = 0;
  String? waitingExchangeId;
  String? detailTitle;
  String? detailText;
  bool waitingTimedOut = false;

  bool get isOpen => mode != G2AgentHistoryMode.closed;
  G2AgentHistoryEntry? get selected =>
      entries.isEmpty ? null : entries[selectedIndex];

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
    mode = G2AgentHistoryMode.detail;
  }

  void showWaiting(AgentExchangeView exchange) {
    waitingExchangeId = exchange.id;
    detailTitle = exchange.agent;
    detailText = 'Waiting for response…';
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
    waitingTimedOut = false;
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
    final title = _oneLine(detailTitle ?? 'History');
    final body = (detailText ?? '').trim();
    return '$title\n${_truncate(body, 430)}\n\n'
        '[ Tap to ${cancel ? 'cancel' : 'dismiss'} ]';
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
