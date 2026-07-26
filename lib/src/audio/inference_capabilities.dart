import 'dart:io';

import 'package:flutter/services.dart';

final class InferenceCapabilities {
  const InferenceCapabilities({
    required this.hasGpu,
    required this.hasNeuralNetworks,
    required this.providers,
    this.description,
  });

  final bool hasGpu;
  final bool hasNeuralNetworks;
  final List<String> providers;
  final String? description;

  static Future<InferenceCapabilities> detect({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_runtime',
    ),
  }) async {
    if (Platform.isAndroid) {
      final raw = await channel.invokeMapMethod<String, Object>(
        'inferenceCapabilities',
      );
      final hasGpu = raw?['hasGpu'] == true;
      final hasNeuralNetworks = raw?['hasNeuralNetworks'] == true;
      return InferenceCapabilities(
        hasGpu: hasGpu,
        hasNeuralNetworks: hasNeuralNetworks,
        // The current Sherpa Android artifact advertises NNAPI but its API-21
        // build falls back to CPU; it also does not contain XNNPACK. Do not
        // mislabel either fallback as accelerated inference.
        providers: const <String>['cpu'],
        description:
            'Android SDK ${raw?['sdkInt'] ?? 'unknown'} · '
            'OpenGL ES 0x${(raw?['glesVersion'] as int? ?? 0).toRadixString(16)} · '
            'NNAPI unavailable in bundled runtime',
      );
    }
    if (Platform.isIOS) {
      return const InferenceCapabilities(
        hasGpu: true,
        hasNeuralNetworks: true,
        providers: <String>['coreml', 'xnnpack', 'cpu'],
        description: 'Core ML compatibility will be verified by warm-up',
      );
    }
    return const InferenceCapabilities(
      hasGpu: false,
      hasNeuralNetworks: false,
      providers: <String>['xnnpack', 'cpu'],
      description: 'No mobile accelerator probe is available',
    );
  }
}
