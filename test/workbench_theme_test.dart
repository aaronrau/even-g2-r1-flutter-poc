import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses a grayscale Material palette except for connected status', () {
    final scheme = workBenchColorScheme;
    final grayscaleColors = <Color>[
      scheme.primary,
      scheme.onPrimary,
      scheme.primaryContainer,
      scheme.onPrimaryContainer,
      scheme.secondary,
      scheme.onSecondary,
      scheme.secondaryContainer,
      scheme.onSecondaryContainer,
      scheme.tertiary,
      scheme.onTertiary,
      scheme.tertiaryContainer,
      scheme.onTertiaryContainer,
      scheme.error,
      scheme.onError,
      scheme.errorContainer,
      scheme.onErrorContainer,
      scheme.surface,
      scheme.onSurface,
      scheme.onSurfaceVariant,
      scheme.outline,
      scheme.outlineVariant,
      scheme.inverseSurface,
      scheme.onInverseSurface,
      scheme.inversePrimary,
      scheme.surfaceTint,
      inactiveStatusColor,
    ];

    expect(grayscaleColors, everyElement(predicate<Color>(_isGrayscale)));
    expect(_isGrayscale(connectedStatusColor), isFalse);
    expect(
      _green(connectedStatusColor),
      greaterThan(_red(connectedStatusColor)),
    );
    expect(
      _green(connectedStatusColor),
      greaterThan(_blue(connectedStatusColor)),
    );
  });

  test('defines the documented type scale and accessible tap targets', () {
    final theme = buildWorkBenchTheme();

    expect(theme.textTheme.titleLarge?.fontSize, 20);
    expect(theme.textTheme.titleMedium?.fontSize, 16);
    expect(theme.textTheme.bodyMedium?.fontSize, 14);
    expect(theme.textTheme.bodySmall?.fontSize, 12);
    expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
  });
}

bool _isGrayscale(Color color) =>
    _red(color) == _green(color) && _green(color) == _blue(color);

int _red(Color color) => (color.toARGB32() >> 16) & 0xff;
int _green(Color color) => (color.toARGB32() >> 8) & 0xff;
int _blue(Color color) => color.toARGB32() & 0xff;
