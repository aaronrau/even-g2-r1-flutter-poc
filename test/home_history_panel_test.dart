import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:even_g2_r1_poc/src/ble/ble_models.dart';
import 'package:even_g2_r1_poc/src/ui/home_history_panel.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('switches between complete events and saved transcriptions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clearCount = 0;
    SharedTranscript? played;
    final selectedTabs = <HomeHistoryTab>[];
    final transcript = SharedTranscript(
      id: 'sample',
      text:
          'Work Bench audio safety check number seven. '
          'The glasses should transcribe every word.',
      audioFileName: 'sample.wav',
      updatedAt: DateTime(2026, 1, 2, 3, 4),
    );

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: <PooledLog>[
            PooledLog(
              timestamp: DateTime(2026, 1, 2, 3, 4),
              source: 'BLE',
              message: 'Adapter ready',
            ),
            PooledLog(
              timestamp: DateTime(2026, 1, 2, 3, 5),
              source: 'Protocol RX',
              message: 'Raw event retained',
            ),
          ],
          transcriptions: <SharedTranscript>[transcript],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingTranscriptions: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
          onClearEvents: () => clearCount++,
          onRefreshTranscriptions: () {},
          onTabChanged: selectedTabs.add,
          onToggleTranscriptAudio: (value) => played = value,
        ),
      ),
    );

    expect(find.textContaining('Adapter ready'), findsOneWidget);
    expect(find.textContaining('Raw event retained'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(SegmentedButton), findsNothing);
    await tester.tap(find.byTooltip('Clear events'));
    expect(clearCount, 1);

    await tester.tap(find.text('Transcriptions'));
    await tester.pumpAndSettle();

    expect(selectedTabs, <HomeHistoryTab>[HomeHistoryTab.transcriptions]);
    expect(find.text(transcript.text), findsOneWidget);
    expect(find.text('Files-visible in Work Bench Audio'), findsOneWidget);
    final playButton = find.byTooltip('Play audio');
    expect(playButton, findsOneWidget);
    expect(tester.getSize(playButton).height, greaterThanOrEqualTo(48));
    await tester.tap(playButton);
    expect(played, same(transcript));
    await tester.tap(find.text('Events'));
    await tester.pumpAndSettle();
    expect(selectedTabs, <HomeHistoryTab>[
      HomeHistoryTab.transcriptions,
      HomeHistoryTab.events,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers the shared folder picker before showing transcripts', (
    tester,
  ) async {
    var chooseCount = 0;
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          transcriptions: const <SharedTranscript>[],
          supportsSharedFolder: true,
          isLoadingTranscriptions: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
          onChooseFolder: () => chooseCount++,
        ),
      ),
    );

    await tester.tap(find.text('Transcriptions'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Choose a shared folder'), findsOneWidget);
    final chooseButton = find.widgetWithText(FilledButton, 'Choose folder');
    expect(chooseButton, findsOneWidget);
    await tester.tap(chooseButton);
    expect(chooseCount, 1);
  });

  testWidgets('shows only the thirty most recent supplied events', (
    tester,
  ) async {
    final events = List<PooledLog>.generate(
      35,
      (index) => PooledLog(
        timestamp: DateTime(2026, 1, 1).add(Duration(minutes: index)),
        source: 'Test',
        message: 'Event $index',
      ),
    ).reversed.toList();

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: events,
          transcriptions: const <SharedTranscript>[],
          supportsSharedFolder: true,
          isLoadingTranscriptions: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
        ),
      ),
    );

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('events-list')),
    );
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.estimatedChildCount, 30);
  });

  testWidgets(
    'reveals saved transcripts in batches of twenty while scrolling',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final transcriptions = List<SharedTranscript>.generate(
        45,
        (index) => SharedTranscript(
          id: 'sample-$index',
          text: 'Transcript $index',
          audioFileName: 'sample-$index.wav',
          updatedAt: DateTime(2026, 1, 1).subtract(Duration(minutes: index)),
        ),
      );

      await tester.pumpWidget(
        _app(
          HomeHistoryPanel(
            events: const <PooledLog>[],
            transcriptions: transcriptions,
            supportsSharedFolder: true,
            sharedFolderName: 'Work Bench Audio',
            isLoadingTranscriptions: false,
            isStorageBusy: false,
            isPlayingTranscript: (_) => false,
          ),
        ),
      );
      await tester.tap(find.text('Transcriptions'));
      await tester.pumpAndSettle();

      expect(_visibleTranscriptItems(tester), 20);
      await _jumpTranscriptListToEnd(tester);
      expect(_visibleTranscriptItems(tester), 40);
      await _jumpTranscriptListToEnd(tester);
      expect(_visibleTranscriptItems(tester), 45);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: buildWorkBenchTheme(),
    home: Scaffold(
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
}

int _visibleTranscriptItems(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.byKey(const ValueKey<String>('transcriptions-list')),
  );
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  final separatedChildCount = delegate.estimatedChildCount!;
  return (separatedChildCount + 1) ~/ 2;
}

Future<void> _jumpTranscriptListToEnd(WidgetTester tester) async {
  final list = find.byKey(const ValueKey<String>('transcriptions-list'));
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  final state = tester.state<ScrollableState>(scrollable);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pump();
  await tester.pump();
}
