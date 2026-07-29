import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import '../protocol/g2_protocol.dart';
import 'g2_voice_level_tracker.dart';

typedef G2AudioAnalysisSink = void Function(G2AudioAnalysisSnapshot snapshot);

final class G2AudioAnalysisSnapshot {
  const G2AudioAnalysisSnapshot({
    required this.globalGain,
    required this.activityLevel,
    required this.noiseFloor,
  });

  final int globalGain;
  final int activityLevel;
  final double? noiseFloor;
}

/// Processes every LC3 frame away from Flutter's UI/BLE event isolate.
///
/// G2 sends roughly 100 frames per second. The worker consumes all of them but
/// publishes only the newest analysis snapshot at 30 Hz, keeping ring receive
/// callbacks and display-command scheduling independent from audio analysis.
final class G2AudioAnalysisWorker {
  G2AudioAnalysisWorker({required G2AudioAnalysisSink onSnapshot})
    : _onSnapshot = onSnapshot;

  static const int _maximumStartupPackets = 32;

  final G2AudioAnalysisSink _onSnapshot;
  final Queue<TransferableTypedData> _startupPackets =
      Queue<TransferableTypedData>();

  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  Isolate? _isolate;
  SendPort? _commandPort;
  Future<void>? _starting;
  bool _disposed = false;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (_disposed) {
      return;
    }
    final ready = Completer<void>();
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    _subscription = receivePort.listen((dynamic message) {
      if (message is SendPort) {
        _commandPort = message;
        while (_startupPackets.isNotEmpty) {
          message.send(_startupPackets.removeFirst());
        }
        if (!ready.isCompleted) {
          ready.complete();
        }
        return;
      }
      if (message is List<Object?> && message.length == 3) {
        _onSnapshot(
          G2AudioAnalysisSnapshot(
            globalGain: message[0]! as int,
            activityLevel: message[1]! as int,
            noiseFloor: message[2] as double?,
          ),
        );
      }
    });
    _isolate = await Isolate.spawn<SendPort>(
      _g2AudioWorkerEntry,
      receivePort.sendPort,
      debugName: 'g2-audio-analysis',
    );
    await ready.future;
  }

  void addPacket(Uint8List packet) {
    if (_disposed) {
      return;
    }
    final transferable = TransferableTypedData.fromList(<TypedData>[packet]);
    final commandPort = _commandPort;
    if (commandPort != null) {
      commandPort.send(transferable);
      return;
    }
    if (_startupPackets.length == _maximumStartupPackets) {
      _startupPackets.removeFirst();
    }
    _startupPackets.addLast(transferable);
    unawaited(start());
  }

  void reset() {
    _startupPackets.clear();
    _commandPort?.send(_resetCommand);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _startupPackets.clear();
    _commandPort?.send(_stopCommand);
    await _subscription?.cancel();
    _subscription = null;
    _receivePort?.close();
    _receivePort = null;
    _commandPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

const String _resetCommand = 'reset';
const String _stopCommand = 'stop';
const Duration _snapshotInterval = Duration(milliseconds: 33);

void _g2AudioWorkerEntry(SendPort output) {
  final commands = ReceivePort();
  final tracker = G2VoiceLevelTracker();
  var dirty = false;
  var latestGain = 0;

  final snapshotTimer = Timer.periodic(_snapshotInterval, (_) {
    if (!dirty) {
      return;
    }
    dirty = false;
    output.send(<Object?>[latestGain, tracker.level, tracker.noiseFloor]);
  });

  commands.listen((dynamic message) {
    if (message is TransferableTypedData) {
      final packet = message.materialize().asUint8List();
      for (var offset = 0; offset + 40 <= packet.length; offset += 40) {
        final gain = G2AudioAnalysis.globalGainIndex(
          Uint8List.sublistView(packet, offset, offset + 40),
        );
        if (gain == null) {
          continue;
        }
        latestGain = gain;
        tracker.addGain(gain);
        dirty = true;
      }
      return;
    }
    if (message == _resetCommand) {
      tracker.reset();
      latestGain = 0;
      dirty = false;
      return;
    }
    if (message == _stopCommand) {
      snapshotTimer.cancel();
      commands.close();
    }
  });
  output.send(commands.sendPort);
}
