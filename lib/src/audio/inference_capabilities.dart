import 'dart:io';

import 'package:flutter/services.dart';

final class InferenceCapabilities {
  const InferenceCapabilities({
    required this.hasGpuHardware,
    required this.hasNnapiApi,
    required this.providers,
    this.description,
  });

  /// Hardware/API hints only. Neither value proves that an ONNX execution
  /// provider can assign model nodes to that accelerator.
  final bool hasGpuHardware;
  final bool hasNnapiApi;
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
      final hasGpuHardware = raw?['hasGpu'] == true;
      final hasNnapiApi = raw?['hasNeuralNetworks'] == true;
      final sdkInt = raw?['sdkInt'] as int? ?? 0;
      final canEnforceHardwareOnlyNnapi = hasNnapiApi && sdkInt >= 29;
      return InferenceCapabilities(
        hasGpuHardware: hasGpuHardware,
        hasNnapiApi: hasNnapiApi,
        providers: canEnforceHardwareOnlyNnapi
            ? const <String>['nnapi', 'cpu']
            : const <String>['cpu'],
        description:
            'Android SDK ${raw?['sdkInt'] ?? 'unknown'} · '
            'OpenGL ES 0x${(raw?['glesVersion'] as int? ?? 0).toRadixString(16)} · '
            'GPU EP unavailable · '
            '${canEnforceHardwareOnlyNnapi ? 'hardware-only NNAPI candidate' : 'CPU'}',
      );
    }
    if (Platform.isIOS) {
      return const InferenceCapabilities(
        hasGpuHardware: true,
        hasNnapiApi: false,
        providers: <String>['coreml', 'xnnpack', 'cpu'],
        description: 'Core ML compatibility will be verified by warm-up',
      );
    }
    return const InferenceCapabilities(
      hasGpuHardware: false,
      hasNnapiApi: false,
      providers: <String>['xnnpack', 'cpu'],
      description: 'No mobile accelerator probe is available',
    );
  }
}
