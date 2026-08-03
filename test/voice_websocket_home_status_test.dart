import 'package:even_g2_r1_poc/src/ui/voice_websocket_home_status.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows only the endpoint for the green ready state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: const Scaffold(
          body: VoiceWebSocketHomeStatus(
            host: '192.0.2.10',
            port: 8787,
            status: VoiceWebSocketStatus.ready,
          ),
        ),
      ),
    );

    expect(find.text('192.0.2.10:8787'), findsOneWidget);
    expect(find.textContaining('Connected'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label ==
                'Agent connection 192.0.2.10:8787, Connected',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(const ValueKey<String>('voice-websocket-status-dot')),
          )
          .color,
      connectedStatusColor,
    );
    final status = tester.getRect(find.byType(VoiceWebSocketHomeStatus));
    final endpoint = tester.getRect(
      find.byKey(const ValueKey<String>('voice-websocket-status-text')),
    );
    expect(endpoint.right, status.right);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses grayscale and text when the socket is not ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: const Scaffold(
          body: VoiceWebSocketHomeStatus(
            host: '192.0.2.10',
            port: 8787,
            status: VoiceWebSocketStatus.disconnected,
          ),
        ),
      ),
    );

    expect(find.text('192.0.2.10:8787 · Disconnected'), findsOneWidget);
    expect(tester.getSize(find.byType(VoiceWebSocketHomeStatus)).width, 154);
    expect(
      tester
          .widget<Icon>(
            find.byKey(const ValueKey<String>('voice-websocket-status-dot')),
          )
          .color,
      inactiveStatusColor,
    );
    expect(tester.takeException(), isNull);
  });
}
