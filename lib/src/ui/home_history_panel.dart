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
  final ValueChanged<SharedTranscript>? onToggleTranscriptAudio;

  @override
  State<HomeHistoryPanel> createState() => _HomeHistoryPanelState();
}

final class _HomeHistoryPanelState extends State<HomeHistoryPanel> {
  HomeHistoryTab _selectedTab = HomeHistoryTab.events;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: SegmentedButton<HomeHistoryTab>(
                segments: const <ButtonSegment<HomeHistoryTab>>[
                  ButtonSegment<HomeHistoryTab>(
                    value: HomeHistoryTab.events,
                    label: Text('Events'),
                  ),
                  ButtonSegment<HomeHistoryTab>(
                    value: HomeHistoryTab.transcriptions,
                    label: Text('Transcriptions'),
                  ),
                ],
                selected: <HomeHistoryTab>{_selectedTab},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _selectedTab = selection.single);
                },
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
          child: _selectedTab == HomeHistoryTab.events
              ? _buildEvents(context)
              : _buildTranscriptions(context),
        ),
      ],
    );
  }

  Widget _buildEvents(BuildContext context) {
    if (widget.events.isEmpty) {
      return Center(
        child: Text('No events', style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('events-list'),
      itemCount: widget.events.length,
      itemExtent: 28,
      itemBuilder: (context, index) {
        final entry = widget.events[index];
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
          child: ListView.separated(
            key: const ValueKey<String>('transcriptions-list'),
            itemCount: widget.transcriptions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final transcript = widget.transcriptions[index];
              final isPlaying = widget.isPlayingTranscript(transcript);
              return Padding(
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
      ],
    );
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
