import 'package:even_g2_r1_poc/src/ui/home_page.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/wearable_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows agent connection first in Tools', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ReactiveBlePlatform.instance = _FakeReactiveBlePlatform();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: HomePage(controller: WearableController()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Tools'));
    await tester.pump();

    final toolsList = tester.widget<ListView>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.padding == const EdgeInsets.all(16),
      ),
    );
    final children =
        (toolsList.childrenDelegate as SliverChildListDelegate).children;

    expect(
      children.first.key,
      const ValueKey<String>('tools-agent-connection'),
    );
    expect(
      children.indexWhere(
        (child) =>
            child.key == const ValueKey<String>('tools-agent-connection'),
      ),
      lessThan(
        children.indexWhere(
          (child) => child.key == const ValueKey<String>('tools-transcription'),
        ),
      ),
    );
    expect(find.byKey(const Key('voice-websocket-ip')), findsOneWidget);
    expect(find.byKey(const Key('voice-websocket-port')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

final class _FakeReactiveBlePlatform extends ReactiveBlePlatform {
  @override
  Stream<BleStatus> get bleStatusStream =>
      Stream<BleStatus>.value(BleStatus.ready);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> deinitialize() async {}
}
