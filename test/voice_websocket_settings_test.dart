import 'package:even_g2_r1_poc/src/ui/voice_websocket_settings.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('validates and saves a private connection on a phone viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VoiceWebSocketConfig? saved;
    var connectCalls = 0;
    var disconnectCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: VoiceWebSocketSettings(
                config: VoiceWebSocketConfig.defaults,
                status: VoiceWebSocketStatus.disconnected,
                statusText: 'Saved · disconnected',
                busy: false,
                onSave: (value) async => saved = value,
                onConnect: () async => connectCalls++,
                onDisconnect: () async => disconnectCalls++,
              ),
            ),
          ),
        ),
      ),
    );

    final ipField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-ip')),
        matching: find.byType(EditableText),
      ),
    );
    final portField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-port')),
        matching: find.byType(EditableText),
      ),
    );
    final secretField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-secret')),
        matching: find.byType(EditableText),
      ),
    );
    expect(
      ipField.keyboardType,
      const TextInputType.numberWithOptions(decimal: true),
    );
    expect(portField.keyboardType, TextInputType.number);
    expect(secretField.obscureText, isTrue);
    expect(find.textContaining('unencrypted'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('voice-websocket-ip')),
      '127.0.0.1',
    );
    await tester.enterText(
      find.byKey(const Key('voice-websocket-port')),
      '8787',
    );
    await tester.enterText(
      find.byKey(const Key('voice-websocket-secret')),
      'example-secret',
    );
    await tester.enterText(
      find.byKey(const Key('voice-websocket-agents')),
      'Agent One\nAgent Two',
    );
    final save = find.widgetWithText(FilledButton, 'Save connection');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saved?.host, '127.0.0.1');
    expect(saved?.port, 8787);
    expect(saved?.secret, 'example-secret');
    expect(saved?.agentNames, <String>['Agent One', 'Agent Two']);
    expect(saved?.authHeader, VoiceWebSocketAuthHeader.authorizationBearer);
    expect(saved?.useLegacyMessageShape, isFalse);
    expect(connectCalls, 0);
    expect(disconnectCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows validation without saving invalid fields', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VoiceWebSocketConfig? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: VoiceWebSocketSettings(
              config: VoiceWebSocketConfig.defaults,
              status: VoiceWebSocketStatus.unconfigured,
              statusText: 'Not configured',
              busy: false,
              onSave: (value) async => saved = value,
              onConnect: () async {},
              onDisconnect: () async {},
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('voice-websocket-ip')),
      '999.0.0.1',
    );
    final save = find.widgetWithText(FilledButton, 'Save connection');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();

    expect(
      find.text('Each IP address number must be from 0 to 255.'),
      findsOneWidget,
    );
    expect(find.text('Secret cannot be empty.'), findsOneWidget);
    expect(find.text('Add at least one agent name.'), findsOneWidget);
    expect(saved, isNull);
  });
}
