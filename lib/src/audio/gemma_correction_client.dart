import 'dart:io';

import 'package:flutter/services.dart';

enum GemmaTextTask {
  transcriptCorrection('transcript_correction'),
  memoRevision('memo_revision');

  const GemmaTextTask(this.wireName);

  final String wireName;
}

final class GemmaCorrectionRequest {
  const GemmaCorrectionRequest({
    required this.modelPath,
    required this.modelId,
    required this.instructions,
    required this.transcript,
    required this.timeoutMs,
    this.task = GemmaTextTask.transcriptCorrection,
  });

  final String modelPath;
  final String modelId;
  final String instructions;
  final String transcript;
  final int timeoutMs;
  final GemmaTextTask task;
}

final class GemmaCorrectionResult {
  const GemmaCorrectionResult({
    required this.correctedText,
    required this.provider,
    required this.engineLoadMs,
    required this.inferenceMs,
    required this.totalMs,
    required this.timeToFirstTokenMs,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
  });

  final String correctedText;
  final String provider;
  final int engineLoadMs;
  final int inferenceMs;
  final int totalMs;
  final int timeToFirstTokenMs;
  final double prefillTokensPerSecond;
  final double decodeTokensPerSecond;
}

abstract interface class GemmaCorrectionClient {
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request);
  Future<void> releaseEngine();
}

final class PlatformGemmaCorrectionClient implements GemmaCorrectionClient {
  PlatformGemmaCorrectionClient({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_gemma',
    ),
    bool? isAndroid,
  }) : _channel = channel,
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    if (!_isAndroid) {
      throw UnsupportedError(
        'On-device Gemma correction is currently available on Android.',
      );
    }
    final response = await _channel
        .invokeMapMethod<String, Object?>('correct', <String, Object>{
          'modelPath': request.modelPath,
          'modelId': request.modelId,
          'instructions': request.instructions,
          'transcript': request.transcript,
          'timeoutMs': request.timeoutMs,
          'task': request.task.wireName,
        })
        .timeout(Duration(milliseconds: request.timeoutMs + 10000));
    final correctedText = response?['correctedText'];
    final provider = response?['provider'];
    if (correctedText is! String ||
        correctedText.trim().isEmpty ||
        provider is! String) {
      throw StateError('The Gemma service returned an invalid response.');
    }
    return GemmaCorrectionResult(
      correctedText: correctedText.trim(),
      provider: provider,
      engineLoadMs: _int(response?['engineLoadMs']),
      inferenceMs: _int(response?['inferenceMs']),
      totalMs: _int(response?['totalMs']),
      timeToFirstTokenMs: _int(response?['timeToFirstTokenMs']),
      prefillTokensPerSecond: _double(response?['prefillTokensPerSecond']),
      decodeTokensPerSecond: _double(response?['decodeTokensPerSecond']),
    );
  }

  @override
  Future<void> releaseEngine() async {
    if (_isAndroid) {
      await _channel.invokeMethod<void>('releaseEngine');
    }
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;
  static double _double(Object? value) => value is num ? value.toDouble() : 0;
}
