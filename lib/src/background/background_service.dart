import 'dart:io';

import 'package:flutter/services.dart';

abstract final class BackgroundConnectionService {
  static const MethodChannel _channel = MethodChannel(
    'dev.opensourceglasses/background_connection',
  );

  static bool _running = false;
  static bool _required = false;
  static bool _reassertRequested = false;
  static Future<void> _operationTail = Future<void>.value();

  static Future<int?> androidSdkInt() async {
    if (!Platform.isAndroid) {
      return null;
    }
    return _channel.invokeMethod<int>('sdkInt');
  }

  static Future<void> setRequired(bool required, {bool reassert = false}) {
    if (!Platform.isAndroid) {
      return Future<void>.value();
    }
    _required = required;
    _reassertRequested = _reassertRequested || reassert;

    final operation = _operationTail.then((_) => _applyRequiredState());
    // A failed platform call is returned to its caller, but does not poison
    // later lifecycle/connection updates.
    _operationTail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  static Future<void> _applyRequiredState() async {
    while (true) {
      final required = _required;
      final reassert = _reassertRequested;
      _reassertRequested = false;

      if (required) {
        if (!_running || reassert) {
          await _channel.invokeMethod<void>('start');
          _running = true;
        }
      } else if (_running || reassert) {
        await _channel.invokeMethod<void>('stop');
        _running = false;
      }

      if (_running == _required && !_reassertRequested) {
        return;
      }
    }
  }
}
