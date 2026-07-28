import 'package:even_g2_r1_poc/src/audio/transcript_correction_config.dart';
import 'package:even_g2_r1_poc/src/ui/transcript_correction_settings.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('validates and saves instructions on a phone-sized viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? saved;
    bool? enabled;
    var resets = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TranscriptCorrectionSettings(
                config: TranscriptCorrectionConfig.defaults,
                runtimeState: 'ready',
                provider: 'gpu',
                pendingCount: 1,
                completedCount: 2,
                busy: false,
                onEnabledChanged: (value) async => enabled = value,
                onSaveInstructions: (value) async => saved = value,
                onResetInstructions: () async => resets++,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('LLM instructions'), findsOneWidget);
    expect(find.textContaining('next transcription'), findsOneWidget);
    expect(find.textContaining('selected shared folder'), findsOneWidget);
    expect(find.textContaining('private fallback'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save instructions'));
    await tester.pump();
    expect(find.text('LLM instructions cannot be empty.'), findsOneWidget);
    expect(saved, isNull);

    await tester.enterText(
      find.byType(TextFormField),
      'Keep product names exactly as spoken.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save instructions'));
    await tester.pumpAndSettle();
    expect(saved, 'Keep product names exactly as spoken.');

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(enabled, isFalse);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset instructions'));
    await tester.pump();
    expect(resets, 1);
    expect(tester.takeException(), isNull);
  });
}
