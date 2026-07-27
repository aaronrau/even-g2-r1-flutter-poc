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
          onToggleTranscriptAudio: (value) => played = value,
        ),
      ),
    );

    expect(find.textContaining('Adapter ready'), findsOneWidget);
    expect(find.textContaining('Raw event retained'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear events'));
    expect(clearCount, 1);

    await tester.tap(find.text('Transcriptions'));
    await tester.pumpAndSettle();

    expect(find.text(transcript.text), findsOneWidget);
    expect(find.text('Files-visible in Work Bench Audio'), findsOneWidget);
    final playButton = find.byTooltip('Play audio');
    expect(playButton, findsOneWidget);
    expect(tester.getSize(playButton).height, greaterThanOrEqualTo(48));
    await tester.tap(playButton);
    expect(played, same(transcript));
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
