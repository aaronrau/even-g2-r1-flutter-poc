import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'background_service.dart';

typedef RuntimeLogSink =
    void Function(String source, String message, {bool isError});

/// Owns the app-level runtime policies that must outlive individual screens.
///
/// BLE connections remain owned by their connection services. This coordinator
/// only keeps the visible app awake and maintains the Android foreground
/// service while a wearable session is active.
final class AppRuntimeCoordinator {
  AppRuntimeCoordinator({required RuntimeLogSink log}) : _log = log;

  final RuntimeLogSink _log;

  bool _initialized = false;
  bool _disposed = false;
  bool _screenAwake = false;

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    await _enableScreenAwake(logSuccess: true);
  }

  Future<void> handleLifecycleState(
    AppLifecycleState state, {
    required bool wearableSessionActive,
  }) async {
    if (_disposed) {
      return;
    }

    // Reassert this on every resume because the platform can recreate the
    // activity/window without recreating this Dart object.
    if (state == AppLifecycleState.resumed) {
      await _enableScreenAwake();
    }

    // Never tear down an active wearable session for a transient lifecycle
    // state. Android gets an idempotent service start; iOS relies on its
    // CoreBluetooth background mode and keeps the Dart-side BLE ownership.
    await setWearableSessionActive(
      wearableSessionActive,
      reassert: wearableSessionActive && state == AppLifecycleState.resumed,
    );
  }

  Future<void> setWearableSessionActive(
    bool active, {
    bool reassert = false,
  }) async {
    if (_disposed) {
      return;
    }
    try {
      await BackgroundConnectionService.setRequired(active, reassert: reassert);
    } catch (error) {
      _log(
        'Background',
        'Could not ${active ? 'maintain' : 'stop'} background operation: '
            '$error',
        isError: true,
      );
    }
  }

  Future<void> _enableScreenAwake({bool logSuccess = false}) async {
    try {
      await WakelockPlus.enable();
      final changed = !_screenAwake;
      _screenAwake = true;
      if (logSuccess || changed) {
        _log('Runtime', 'Screen sleep prevention enabled');
      }
    } catch (error) {
      _screenAwake = false;
      _log(
        'Runtime',
        'Could not enable screen sleep prevention: $error',
        isError: true,
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      // Force a native stop as cleanup even if this Dart isolate did not
      // originally start a still-running service.
      await BackgroundConnectionService.setRequired(false, reassert: true);
    } catch (error) {
      _log(
        'Background',
        'Could not stop background operation during shutdown: $error',
        isError: true,
      );
    }
    if (_screenAwake) {
      try {
        await WakelockPlus.disable();
      } catch (error) {
        _log(
          'Runtime',
          'Could not release screen sleep prevention: $error',
          isError: true,
        );
      }
    }
    _screenAwake = false;
    _initialized = false;
  }
}
