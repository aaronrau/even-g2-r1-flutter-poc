import 'dart:math';

import 'package:flutter/material.dart';

import '../audio/shared_audio_export_store.dart';
import '../ble/ble_models.dart';

enum HomeHistoryTab { events, messages }

final class HomeHistoryPanel extends StatefulWidget {
  const HomeHistoryPanel({
    required this.events,
    required this.messages,
    required this.transcriptions,
    required this.supportsSharedFolder,
    required this.isLoadingMessages,
    required this.isStorageBusy,
    required this.isPlayingTranscript,
    this.sharedFolderName,
    this.messageError,
    this.onClearEvents,
    this.onChooseFolder,
    this.onRefreshMessages,
    this.onTabChanged,
    this.onToggleTranscriptAudio,
    super.key,
  });

  final List<PooledLog> events;
  final List<SharedWebSocketMessage> messages;
  final List<SharedTranscript> transcriptions;
  final bool supportsSharedFolder;
  final bool isLoadingMessages;
  final bool isStorageBusy;
  final bool Function(SharedTranscript transcript) isPlayingTranscript;
  final String? sharedFolderName;
  final String? messageError;
  final VoidCallback? onClearEvents;
  final VoidCallback? onChooseFolder;
  final VoidCallback? onRefreshMessages;
  final ValueChanged<HomeHistoryTab>? onTabChanged;
  final ValueChanged<SharedTranscript>? onToggleTranscriptAudio;

  @override
  State<HomeHistoryPanel> createState() => _HomeHistoryPanelState();
}

final class _HomeHistoryPanelState extends State<HomeHistoryPanel>
    with SingleTickerProviderStateMixin {
  static const int _messagePageSize = 20;

  late final TabController _tabController;
  int _visibleMessageCount = _messagePageSize;
  HomeHistoryTab _reportedTab = HomeHistoryTab.events;

  HomeHistoryTab get _selectedTab =>
      HomeHistoryTab.values[_tabController.index];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: HomeHistoryTab.values.length,
      vsync: this,
    )..addListener(_tabChanged);
  }

  @override
  void didUpdateWidget(HomeHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sharedFolderName != widget.sharedFolderName ||
        oldWidget.messages.length != widget.messages.length ||
        oldWidget.transcriptions.length != widget.transcriptions.length) {
      _visibleMessageCount = _messagePageSize;
    }
  }

  @override
  void dispose() {
    if (_reportedTab == HomeHistoryTab.messages) {
      widget.onTabChanged?.call(HomeHistoryTab.events);
    }
    _tabController
      ..removeListener(_tabChanged)
      ..dispose();
    super.dispose();
  }

  void _tabChanged() {
    if (!mounted) {
      return;
    }
    final selectedTab = _selectedTab;
    if (selectedTab != _reportedTab) {
      _reportedTab = selectedTab;
      widget.onTabChanged?.call(selectedTab);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TabBar(
                controller: _tabController,
                dividerColor: Theme.of(context).colorScheme.outlineVariant,
                indicatorColor: Theme.of(context).colorScheme.onSurface,
                indicatorSize: TabBarIndicatorSize.tab,
                labelStyle: Theme.of(context).textTheme.titleSmall,
                unselectedLabelStyle: Theme.of(context).textTheme.bodyMedium,
                tabs: const <Tab>[
                  Tab(height: 48, text: 'Events'),
                  Tab(height: 48, text: 'Messages'),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_selectedTab == HomeHistoryTab.events)
              IconButton(
                tooltip: 'Clear events',
                onPressed: widget.events.isEmpty ? null : widget.onClearEvents,
                icon: const Icon(Icons.clear_all),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              )
            else
              IconButton(
                tooltip: 'Refresh messages',
                onPressed:
                    widget.sharedFolderName == null ||
                        widget.isLoadingMessages ||
                        widget.isStorageBusy
                    ? null
                    : widget.onRefreshMessages,
                icon: const Icon(Icons.refresh),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: <Widget>[_buildEvents(context), _buildMessages(context)],
          ),
        ),
      ],
    );
  }

  Widget _buildEvents(BuildContext context) {
    final events = widget.events.take(30).toList(growable: false);
    if (events.isEmpty) {
      return Center(
        child: Text('No events', style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('events-list'),
      itemCount: events.length,
      itemExtent: 28,
      itemBuilder: (context, index) {
        final entry = events[index];
        final time =
            '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
            '${entry.timestamp.minute.toString().padLeft(2, '0')}';
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '$time  ${entry.source}  ${_singleLine(entry.message)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: entry.isError ? Theme.of(context).colorScheme.error : null,
              fontFamily: 'monospace',
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessages(BuildContext context) {
    final theme = Theme.of(context);
    final folderName = widget.sharedFolderName;
    if (folderName == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.supportsSharedFolder
                    ? 'Choose a shared folder to browse sent and received '
                          'messages, transcripts, and WAV audio.'
                    : 'Shared message folders are available on Android.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (widget.supportsSharedFolder) ...<Widget>[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: widget.isStorageBusy
                      ? null
                      : widget.onChooseFolder,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Choose folder'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (widget.isLoadingMessages) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = widget.messageError;
    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.isStorageBusy
                    ? null
                    : widget.onRefreshMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final history = _messageHistory();
    if (history.isEmpty) {
      return Center(
        child: Text(
          'No saved messages in $folderName',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final visibleCount = min(_visibleMessageCount, history.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Messages and transcripts in $folderName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) =>
                _loadMoreMessages(notification, history.length),
            child: ListView.separated(
              key: const ValueKey<String>('messages-list'),
              itemCount: visibleCount,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = history[index];
                final message = entry.message;
                if (message != null) {
                  return _buildWebSocketMessage(context, message);
                }
                final transcript = entry.transcript!;
                final isPlaying = widget.isPlayingTranscript(transcript);
                return Padding(
                  key: ValueKey<String>('transcript-${transcript.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Original', style: theme.textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              transcript.originalText,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Corrected',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              transcript.correctedText ??
                                  'Correction pending or unavailable',
                              style: transcript.hasCorrection
                                  ? theme.textTheme.bodyMedium
                                  : theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${transcript.hasAudio ? 'WAV + transcript' : 'Transcript only'}'
                              ' · ${transcript.hasCorrection ? 'corrected' : 'original only'}'
                              ' · ${_savedLabel(context, transcript.updatedAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: transcript.hasAudio
                            ? isPlaying
                                  ? 'Stop audio'
                                  : 'Play audio'
                            : 'Audio unavailable',
                        onPressed: !transcript.hasAudio || widget.isStorageBusy
                            ? null
                            : () => widget.onToggleTranscriptAudio?.call(
                                transcript,
                              ),
                        icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  List<_MessageHistoryEntry> _messageHistory() {
    final history = <_MessageHistoryEntry>[
      for (final message in widget.messages)
        _MessageHistoryEntry.message(message),
      for (final transcript in widget.transcriptions)
        _MessageHistoryEntry.transcript(transcript),
    ];
    history.sort((left, right) {
      final byTime = right.updatedAt.compareTo(left.updatedAt);
      return byTime != 0 ? byTime : right.id.compareTo(left.id);
    });
    return history;
  }

  Widget _buildWebSocketMessage(
    BuildContext context,
    SharedWebSocketMessage message,
  ) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey<String>('message-${message.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message.direction.label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(message.text, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            _savedLabel(context, message.updatedAt),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  bool _loadMoreMessages(ScrollNotification notification, int historyLength) {
    if (notification is! ScrollEndNotification ||
        notification.metrics.extentAfter > 160 ||
        _visibleMessageCount >= historyLength) {
      return false;
    }
    setState(() {
      _visibleMessageCount = min(
        _visibleMessageCount + _messagePageSize,
        historyLength,
      );
    });
    return false;
  }

  String _savedLabel(BuildContext context, DateTime updatedAt) {
    if (updatedAt.millisecondsSinceEpoch <= 0) {
      return 'shared folder';
    }
    final local = updatedAt.toLocal();
    final now = DateTime.now();
    final localizations = MaterialLocalizations.of(context);
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    }
    return localizations.formatCompactDate(local);
  }

  String _singleLine(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

final class _MessageHistoryEntry {
  const _MessageHistoryEntry._({
    required this.id,
    required this.updatedAt,
    this.message,
    this.transcript,
  });

  factory _MessageHistoryEntry.message(SharedWebSocketMessage value) =>
      _MessageHistoryEntry._(
        id: 'message-${value.id}',
        updatedAt: value.updatedAt,
        message: value,
      );

  factory _MessageHistoryEntry.transcript(SharedTranscript value) =>
      _MessageHistoryEntry._(
        id: 'transcript-${value.id}',
        updatedAt: value.updatedAt,
        transcript: value,
      );

  final String id;
  final DateTime updatedAt;
  final SharedWebSocketMessage? message;
  final SharedTranscript? transcript;
}
