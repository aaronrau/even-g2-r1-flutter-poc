import 'package:flutter/services.dart';

final class Lc3Decoder {
  Lc3Decoder({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_lc3',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  bool _initialized = false;

  Future<void> initialize() async {
    final initialized = await _channel.invokeMethod<bool>('initialize');
    if (initialized != true) {
      throw StateError('The native LC3 decoder did not initialize.');
    }
    final silentFrame = Uint8List(40);
    final decoded = await decode(silentFrame);
    if (decoded.length != 320) {
      throw StateError(
        'LC3 self-test returned ${decoded.length} bytes; expected 320.',
      );
    }
    _initialized = true;
  }

  Future<Uint8List> decode(Uint8List packet) async {
    if (packet.isEmpty || packet.length % 40 != 0) {
      throw ArgumentError.value(
        packet.length,
        'packet.length',
        'LC3 input must contain complete 40-byte frames',
      );
    }
    final result = await _channel.invokeMethod<Uint8List>(
      'decode',
      <String, Object>{'bytes': packet, 'frameSize': 40},
    );
    if (result == null || result.length != packet.length ~/ 40 * 320) {
      throw StateError(
        'LC3 decode failed for ${packet.length ~/ 40} frame(s).',
      );
    }
    return result;
  }

  Future<void> dispose() async {
    if (!_initialized) {
      return;
    }
    _initialized = false;
    await _channel.invokeMethod<void>('dispose');
  }
}
