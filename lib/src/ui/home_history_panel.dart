import 'dart:math';

import 'package:flutter/material.dart';

import '../audio/shared_audio_export_store.dart';
import '../ble/ble_models.dart';

enum HomeHistoryTab { events, transcriptions }

final class HomeHistoryPanel extends StatefulWidget {
  const HomeHistoryPanel({
    required this.events,
    required this.transcriptions,
    required this.supportsSharedFolder,
    required this.isLoadingTranscriptions,
    required this.isStorageBusy,
    required this.isPlayingTranscript,
    this.sharedFolderName,
    this.transcriptionError,
    this.onClearEvents,
    this.onChooseFolder,
    this.onRefreshTranscriptions,
    this.onTabChanged,
    this.onToggleTranscriptAudio,
    super.key,
  });

  final List<PooledLog> events;
  final List<SharedTranscript> transcriptions;
  final bool supportsSharedFolder;
  final bool isLoadingTranscriptions;
  final bool isStorageBusy;
  final bool Function(SharedTranscript transcript) isPlayingTranscript;
  final String? sharedFolderName;
  final String? transcriptionError;
  final VoidCallback? onClearEvents;
  final VoidCallback? onChooseFolder;
  final VoidCallback? onRefreshTranscriptions;
  final ValueChanged<HomeHistoryTab>? onTabChanged;
  final ValueChanged<SharedTranscript>? onToggleTranscriptAudio;

  @override
  State<HomeHistoryPanel> createState() => _HomeHistoryPanelState();
}

final class _HomeHistoryPanelState extends State<HomeHistoryPanel>
    with SingleTickerProviderStateMixin {
  static const int _transcriptPageSize = 20;

  late final TabController _tabController;
  int _visibleTranscriptCount = _transcriptPageSize;
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
    if (oldWidget.sharedFolderName != widget.sharedFolderName) {
      _visibleTranscriptCount = _transcriptPageSize;
    }
  }

  @override
  void dispose() {
    if (_reportedTab == HomeHistoryTab.transcriptions) {
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
                  Tab(height: 48, text: 'Transcriptions'),
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
                tooltip: 'Refresh transcriptions',
                onPressed:
                    widget.sharedFolderName == null ||
                        widget.isLoadingTranscriptions ||
                        widget.isStorageBusy
                    ? null
                    : widget.onRefreshTranscriptions,
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
            children: <Widget>[
              _buildEvents(context),
              _buildTranscriptions(context),
            ],
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

  Widget _buildTranscriptions(BuildContext context) {
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
                    ? 'Choose a shared folder to browse saved transcripts '
                          'and play their WAV audio.'
                    : 'Shared transcription folders are available on Android.',
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
    if (widget.isLoadingTranscriptions) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = widget.transcriptionError;
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
                    : widget.onRefreshTranscriptions,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (widget.transcriptions.isEmpty) {
      return Center(
        child: Text(
          'No saved transcriptions in $folderName',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final visibleCount = min(
      _visibleTranscriptCount,
      widget.transcriptions.length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Files-visible in $folderName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _loadMoreTranscripts,
            child: ListView.separated(
              key: const ValueKey<String>('transcriptions-list'),
              itemCount: visibleCount,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final transcript = widget.transcriptions[index];
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
                            Text(
                              transcript.text,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${transcript.hasAudio ? 'WAV + transcript' : 'Transcript only'}'
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

  bool _loadMoreTranscripts(ScrollNotification notification) {
    if (notification is! ScrollEndNotification ||
        notification.metrics.extentAfter > 160 ||
        _visibleTranscriptCount >= widget.transcriptions.length) {
      return false;
    }
    setState(() {
      _visibleTranscriptCount = min(
        _visibleTranscriptCount + _transcriptPageSize,
        widget.transcriptions.length,
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
