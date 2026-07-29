import 'dart:async';

import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:even_g2_r1_poc/src/ble/ble_models.dart';
import 'package:even_g2_r1_poc/src/ui/home_history_panel.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('switches between events and aligned speaker turns', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clearCount = 0;
    var refreshCount = 0;
    var resetPrimaryCount = 0;
    final selectedTabs = <HomeHistoryTab>[];
    final now = DateTime(2026, 1, 2, 3, 4);

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: <PooledLog>[
            PooledLog(timestamp: now, source: 'BLE', message: 'Adapter ready'),
            PooledLog(
              timestamp: now.add(const Duration(minutes: 1)),
              source: 'Protocol RX',
              message: 'Raw event retained',
            ),
          ],
          conversations: <SharedConversationTurn>[
            _turn(
              id: 'turn-1',
              label: 'You',
              text: 'Start the safety check.',
              updatedAt: now,
              primary: true,
            ),
            _turn(
              id: 'turn-2',
              label: 'Speaker 2',
              text: 'The safety check is complete.',
              updatedAt: now.add(const Duration(seconds: 1)),
            ),
          ],
          analysisEnabled: true,
          needsEnrollment: false,
          analysisState: 'ready',
          knownSpeakerCount: 2,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onClearEvents: () => clearCount++,
          onRefreshConversations: () => refreshCount++,
          onResetPrimarySpeaker: () => resetPrimaryCount++,
          onTabChanged: selectedTabs.add,
        ),
      ),
    );

    expect(find.textContaining('Adapter ready'), findsOneWidget);
    expect(find.textContaining('Raw event retained'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(SegmentedButton), findsNothing);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear events'));
    expect(clearCount, 1);

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(selectedTabs, <HomeHistoryTab>[HomeHistoryTab.conversations]);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Start the safety check.'), findsOneWidget);
    expect(find.text('Speaker 2'), findsOneWidget);
    expect(find.text('The safety check is complete.'), findsOneWidget);
    expect(find.textContaining('2 saved speakers'), findsOneWidget);
    final youMarkerFinder = find.byKey(
      const ValueKey<String>('conversation-speaker-color-turn-1'),
    );
    expect(tester.getSize(youMarkerFinder), const Size.square(12));
    final youMarker = tester.widget<Container>(youMarkerFinder);
    final youDecoration = youMarker.decoration as BoxDecoration;
    expect(youDecoration.color, conversationUserMarkerColor);
    expect(youDecoration.shape, BoxShape.circle);
    expect(
      conversationUserMarkerColor.computeLuminance(),
      greaterThan(
        Theme.of(
          tester.element(find.byType(HomeHistoryPanel)),
        ).colorScheme.surfaceContainerHighest.computeLuminance(),
      ),
    );
    expect(
      tester.widget<Text>(find.text('You')).style?.color,
      Theme.of(
        tester.element(find.byType(HomeHistoryPanel)),
      ).colorScheme.onSurface,
    );
    final youTurn = find.byKey(const ValueKey<String>('conversation-turn-1'));
    expect(
      find.descendant(
        of: youTurn,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).borderRadius != null,
        ),
      ),
      findsNothing,
    );
    final resetPrimary = find.byKey(
      const ValueKey<String>('reset-primary-speaker'),
    );
    expect(tester.getSize(resetPrimary).height, greaterThanOrEqualTo(48));
    await tester.tap(resetPrimary);
    expect(resetPrimaryCount, 1);
    final refresh = find.byTooltip('Refresh conversations');
    expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
    await tester.tap(refresh);
    expect(refreshCount, 1);
    await tester.tap(find.text('Events'));
    await tester.pumpAndSettle();
    expect(selectedTabs, <HomeHistoryTab>[
      HomeHistoryTab.conversations,
      HomeHistoryTab.events,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains how to enable optional conversation analysis', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const HomeHistoryPanel(
          events: <PooledLog>[],
          conversations: <SharedConversationTurn>[],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Enable Conversation analysis in Tools'),
      findsOneWidget,
    );
  });

  testWidgets('keeps saved agent messages and transcripts in Messages only', (
    tester,
  ) async {
    SharedTranscript? played;
    final transcript = SharedTranscript(
      id: 'legacy',
      originalText: 'Original synthetic transcript.',
      correctedText: 'Corrected synthetic transcript.',
      audioFileName: 'legacy.wav',
      updatedAt: DateTime(2026, 1, 1),
    );
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: <SharedWebSocketMessage>[
            SharedWebSocketMessage(
              id: 'received',
              direction: SharedWebSocketMessageDirection.received,
              text: 'Synthetic agent response.',
              updatedAt: DateTime(2026, 1, 1, 0, 0, 1),
            ),
          ],
          transcriptions: <SharedTranscript>[transcript],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
          onToggleTranscriptAudio: (value) => played = value,
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Synthetic agent response.'), findsOneWidget);
    expect(find.text('Original synthetic transcript.'), findsOneWidget);
    expect(find.text('Corrected synthetic transcript.'), findsOneWidget);
    await tester.tap(find.byTooltip('Play audio'));
    expect(played, same(transcript));

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic agent response.'), findsNothing);
    expect(find.text('Original synthetic transcript.'), findsNothing);
    expect(find.textContaining('separate Messages tab'), findsOneWidget);
  });

  testWidgets('retains the original Messages folder picker', (tester) async {
    var chooseCount = 0;
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          supportsSharedFolder: true,
          isLoadingMessages: false,
          onChooseFolder: () => chooseCount++,
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Choose a shared folder'), findsOneWidget);
    final chooseButton = find.widgetWithText(FilledButton, 'Choose folder');
    expect(chooseButton, findsOneWidget);
    await tester.tap(chooseButton);
    expect(chooseCount, 1);
  });

  testWidgets('shows first-load indicators for Messages and Conversation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messagesLoaded = Completer<void>();
    final conversationsLoaded = Completer<void>();
    var messageLoads = 0;
    var conversationLoads = 0;

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: const <SharedWebSocketMessage>[],
          transcriptions: const <SharedTranscript>[],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: true,
          needsEnrollment: false,
          analysisState: 'ready',
          knownSpeakerCount: 1,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onLoadMessages: () {
            messageLoads++;
            return messagesLoaded.future;
          },
          onLoadConversations: () {
            conversationLoads++;
            return conversationsLoaded.future;
          },
        ),
      ),
    );

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index =
        HomeHistoryTab.messages.index;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(messageLoads, 1);
    expect(
      find.byKey(const ValueKey<String>('messages-loading')),
      findsOneWidget,
    );
    expect(find.text('Loading messages…'), findsOneWidget);
    expect(find.textContaining('No saved messages'), findsNothing);

    messagesLoaded.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('messages-loading')),
      findsNothing,
    );
    expect(find.textContaining('No saved messages'), findsOneWidget);

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index =
        HomeHistoryTab.conversations.index;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(conversationLoads, 1);
    expect(
      find.byKey(const ValueKey<String>('conversations-loading')),
      findsOneWidget,
    );
    expect(find.text('Loading conversations…'), findsOneWidget);
    expect(find.text('No speaker-labeled conversations yet.'), findsNothing);

    conversationsLoaded.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('conversations-loading')),
      findsNothing,
    );
    expect(find.text('No speaker-labeled conversations yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps a fast first-load indicator visible through tab entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: const <SharedWebSocketMessage>[],
          transcriptions: const <SharedTranscript>[],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onLoadMessages: () async {},
        ),
      ),
    );

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index =
        HomeHistoryTab.messages.index;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Loading messages…'), findsOneWidget);
    expect(find.textContaining('No saved messages'), findsNothing);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Loading messages…'), findsNothing);
    expect(find.textContaining('No saved messages'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks for one clear enrollment sentence', (tester) async {
    await tester.pumpWidget(
      _app(
        const HomeHistoryPanel(
          events: <PooledLog>[],
          conversations: <SharedConversationTurn>[],
          analysisEnabled: true,
          needsEnrollment: true,
          analysisState: 'waiting_for_enrollment_speech',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Speak one clear sentence'), findsOneWidget);
    expect(find.textContaining('“You” voice signature'), findsOneWidget);
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
          conversations: const <SharedConversationTurn>[],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('events-list')),
    );
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.estimatedChildCount, 30);
  });

  testWidgets('retains only the twenty most recent Messages items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transcriptions = List<SharedTranscript>.generate(
      45,
      (index) => SharedTranscript(
        id: 'sample-$index',
        originalText: 'Transcript $index',
        correctedText: 'Corrected transcript $index',
        audioFileName: 'sample-$index.wav',
        updatedAt: DateTime(2026, 1, 1).subtract(Duration(minutes: index)),
      ),
    );

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: const <SharedWebSocketMessage>[],
          transcriptions: transcriptions,
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
        ),
      ),
    );
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(_visibleMessageItems(tester), 20);
    await _jumpListToEnd(tester, 'messages-list');
    expect(_visibleMessageItems(tester), 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retains only the hundred most recent conversation turns', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final turns = List<SharedConversationTurn>.generate(
      225,
      (index) => _turn(
        id: 'turn-$index',
        label: index.isEven ? 'You' : 'Speaker 2',
        text: 'Conversation turn $index',
        updatedAt: DateTime(2026, 1, 1).add(Duration(seconds: index)),
        primary: index.isEven,
      ),
    );

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: turns,
          analysisEnabled: true,
          needsEnrollment: false,
          analysisState: 'ready',
          knownSpeakerCount: 2,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );
    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(_visibleConversationItems(tester), 100);
    expect(find.text('Conversation turn 224'), findsWidgets);
    await _jumpListToEnd(tester, 'conversation-list');
    expect(_visibleConversationItems(tester), 100);
    expect(find.text('Conversation turn 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

SharedConversationTurn _turn({
  required String id,
  required String label,
  required String text,
  required DateTime updatedAt,
  bool primary = false,
}) => SharedConversationTurn(
  id: id,
  conversationId: 'conversation',
  speakerId: primary ? 'primary-user' : 'speaker-2',
  speakerLabel: label,
  text: text,
  startMs: 0,
  endMs: 1000,
  confidence: 0.9,
  updatedAt: updatedAt,
  isPrimary: primary,
  isOverlap: false,
);

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

int _visibleConversationItems(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.byKey(const ValueKey<String>('conversation-list')),
  );
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  final separatedChildCount = delegate.estimatedChildCount!;
  return (separatedChildCount + 1) ~/ 2;
}

int _visibleMessageItems(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.byKey(const ValueKey<String>('messages-list')),
  );
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  final separatedChildCount = delegate.estimatedChildCount!;
  return (separatedChildCount + 1) ~/ 2;
}

Future<void> _jumpListToEnd(WidgetTester tester, String key) async {
  final list = find.byKey(ValueKey<String>(key));
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  final state = tester.state<ScrollableState>(scrollable);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pump();
  await tester.pump();
}
