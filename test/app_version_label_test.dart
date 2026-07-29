import 'package:even_g2_r1_poc/src/ui/app_version_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('shows the package version and build before the Tools button', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: <Widget>[
              AppVersionLabel(
                loadPackageInfo: () async => PackageInfo(
                  appName: 'Work Bench',
                  packageName: 'example.invalid.workbench',
                  version: '2.3.4',
                  buildNumber: '57',
                ),
              ),
              IconButton(
                tooltip: 'Tools',
                onPressed: () {},
                icon: const Icon(Icons.tune_outlined),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('v2.3.4 b57'), findsOneWidget);
    expect(
      tester.getCenter(find.text('v2.3.4 b57')).dx,
      lessThan(tester.getCenter(find.byTooltip('Tools')).dx),
    );
    expect(tester.takeException(), isNull);
  });
}
