import 'dart:async';
import 'dart:io';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter/services.dart';

import '../protocol/r1_protocol.dart';
import '../util/hex.dart';
import 'ble_models.dart';

abstract final class R1Ids {
  static const service = 'bae80001-4f05-4503-8e65-3af1f7329d1f';
  static const write1 = 'bae80010-4f05-4503-8e65-3af1f7329d1f';
  static const notify1 = 'bae80011-4f05-4503-8e65-3af1f7329d1f';
  static const write2 = 'bae80012-4f05-4503-8e65-3af1f7329d1f';
  static const notify2 = 'bae80013-4f05-4503-8e65-3af1f7329d1f';
  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
}

final class R1PairingException implements Exception {
  const R1PairingException();

  @override
  String toString() {
    return 'R1 pairing was rejected or timed out. The ring may still be '
        'bound to another phone. Forget EVEN R1 on the old phone, or restart '
        'the ring on its powered dock with five quick TouchPad taps, then '
        'scan and connect again.';
  }
}

final class R1Connection {
  static const MethodChannel _bondChannel = MethodChannel(
    'dev.opensourceglasses/r1_bond',
  );

  R1Connection({
    required FlutterReactiveBle ble,
    required WearableLogSink log,
    required void Function() onChanged,
  }) : _ble = ble,
       _log = log,
       _onChanged = onChanged;

  final FlutterReactiveBle _ble;
  final WearableLogSink _log;
  final void Function() _onChanged;

  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  final List<StreamSubscription<List<int>>> _notificationSubscriptions =
      <StreamSubscription<List<int>>>[];
  Timer? _batteryTimer;
  Timer? _reconnectTimer;
  DiscoveredDevice? _target;
  QualifiedCharacteristic? _write1;
  QualifiedCharacteristic? _write2;
  QualifiedCharacteristic? _battery;
  bool _manualDisconnect = false;
  bool _awaitingBond = false;
  int _generation = 0;
  int _transactionId = 0;
  String? _setupGlassesMac;
  final Map<int, Completer<R1DecodedFrame>> _pendingResponses =
      <int, Completer<R1DecodedFrame>>{};

  LinkState state = LinkState.disconnected;
  int? batteryLevel;
  String? lastGesture;
  DateTime? lastGestureAt;
  int receivedPackets = 0;
  int receivedBytes = 0;
  String? lastResponseHex;
  String? lastResponseSource;
  DateTime? lastResponseAt;
  int unsolicitedPackets = 0;
  int unclassifiedPackets = 0;
  String? lastProtocolSummary;
  String? lastFirmwareEvent;
  String? lastFirmwareAscii;
  DateTime? lastFirmwareEventAt;
  String? lastTouchStatus;
  String? handoffStatus;
  DateTime? handoffAt;

  bool get isConnected => state == LinkState.connected;
  String? get deviceId => _target?.id;
  String? get deviceName => _target?.name;

  Future<void> connect(DiscoveredDevice target, {String? glassesMac}) async {
    batteryLevel = null;
    _target = target;
    _setupGlassesMac = glassesMac;
    _manualDisconnect = true;
    await _teardown();
    _manualDisconnect = false;
    final generation = ++_generation;
    state = LinkState.connecting;
    _onChanged();
    _log('R1', 'Connecting to ${target.name} (${target.id})');

    final completer = Completer<void>();
    var configuring = false;
    var configured = false;
    final service = Uuid.parse(R1Ids.service);
    _connectionSubscription = _ble
        .connectToDevice(
          id: target.id,
          servicesWithCharacteristicsToDiscover: <Uuid, List<Uuid>>{
            service: <Uuid>[
              Uuid.parse(R1Ids.write1),
              Uuid.parse(R1Ids.notify1),
              Uuid.parse(R1Ids.write2),
              Uuid.parse(R1Ids.notify2),
            ],
            Uuid.parse(R1Ids.batteryService): <Uuid>[
              Uuid.parse(R1Ids.batteryLevel),
            ],
          },
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
          (update) {
            if (generation != _generation) {
              return;
            }
            _log('R1', update.connectionState.name);
            switch (update.connectionState) {
              case DeviceConnectionState.connected:
                if (!configuring) {
                  configuring = true;
                  unawaited(
                    _configure(target)
                        .then((_) {
                          configured = true;
                          if (!completer.isCompleted) {
                            completer.complete();
                          }
                        })
                        .catchError((Object error, StackTrace stackTrace) {
                          if (!completer.isCompleted) {
                            completer.completeError(error, stackTrace);
                          }
                        }),
                  );
                }
              case DeviceConnectionState.disconnected:
                if (!completer.isCompleted) {
                  completer.completeError(
                    _awaitingBond
                        ? const R1PairingException()
                        : StateError('R1 disconnected during setup'),
                  );
                } else if (configured && !_manualDisconnect) {
                  _handleUnexpectedDisconnect();
                }
              case DeviceConnectionState.connecting:
              case DeviceConnectionState.disconnecting:
                break;
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            } else if (configured && !_manualDisconnect) {
              _handleUnexpectedDisconnect();
            }
          },
        );

    try {
      await completer.future;
      state = LinkState.connected;
      _onChanged();
      _startBatteryPolling();
      _log('R1', 'Notifications enabled; ring is ready');
    } catch (error) {
      state = LinkState.error;
      _onChanged();
      _log('R1', 'Connection failed: $error', isError: true);
      rethrow;
    }
  }

  Future<void> _configure(DiscoveredDevice target) async {
    _write1 = _characteristic(target.id, R1Ids.service, R1Ids.write1);
    _write2 = _characteristic(target.id, R1Ids.service, R1Ids.write2);
    _battery = await _findOptionalBattery(target.id);

    try {
      final mtu = await _ble.requestMtu(deviceId: target.id, mtu: 247);
      _log('R1', 'Negotiated ATT MTU $mtu');
    } catch (error) {
      _log('R1', 'MTU request unavailable; continuing: $error');
    }

    _subscribe(
      _characteristic(target.id, R1Ids.service, R1Ids.notify1),
      'notify1',
    );
    _subscribe(
      _characteristic(target.id, R1Ids.service, R1Ids.notify2),
      'notify2',
    );
    final battery = _battery;
    if (battery != null) {
      _subscribe(battery, 'battery');
    }

    // flutter_reactive_ble begins CCCD setup asynchronously when each stream is
    // listened to. Let both descriptor writes settle before PairAuth.
    _log('R1', 'Waiting for both notification subscriptions to settle');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await _startOfficialSession();
    await _readBattery();
  }

  Future<void> _startOfficialSession() async {
    final authTransaction = _nextTransactionId();
    await _write(
      _write2 ?? _write1,
      R1Protocol.pairAuth(serialId: authTransaction),
    );
    _log('R1 session', 'PairAuth sent (transaction $authTransaction)');

    // Complete the secured phone bond before asking the ring to advertise to
    // the G2. The ring rejects advStart while Android is still bonding.
    _awaitingBond = true;
    try {
      await _waitForBond();
    } finally {
      _awaitingBond = false;
    }

    final timeTransaction = _nextTransactionId();
    await _write(
      _write2 ?? _write1,
      R1Protocol.systemTime(time: DateTime.now(), serialId: timeTransaction),
    );
    _log('R1 session', 'Clock synchronized (transaction $timeTransaction)');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await _queryFirmwareStatus(
      label: 'device status',
      command: R1Protocol.deviceStatus,
    );

    final touchTransaction = _nextTransactionId();
    await _write(
      _write2 ?? _write1,
      R1Protocol.touchSwitch(enabled: true, serialId: touchTransaction),
    );
    _log(
      'R1 session',
      'TouchPad enabled (transaction $touchTransaction); this does not '
          'guarantee that gesture packets are routed to the phone',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final statusTransaction = _nextTransactionId();
    final statusResponse = Completer<R1DecodedFrame>();
    _pendingResponses[statusTransaction] = statusResponse;
    try {
      await _write(
        _write2 ?? _write1,
        R1Protocol.touchStatus(serialId: statusTransaction),
      );
      _log(
        'R1 touch status',
        'Read requested (transaction $statusTransaction)',
      );
      final result = await statusResponse.future.timeout(
        const Duration(seconds: 2),
      );
      final payload = result.data.isEmpty
          ? 'no payload'
          : hexOf(result.data, maxBytes: result.data.length);
      lastTouchStatus =
          '${result.statusType}/${result.statusMethod}/${result.statusAck} • '
          '$payload';
      _onChanged();
      _log('R1 touch status', lastTouchStatus!);
    } on TimeoutException {
      lastTouchStatus = 'no acknowledgement from firmware';
      _onChanged();
      _log('R1 touch status', lastTouchStatus!, isError: true);
    } finally {
      if (identical(_pendingResponses[statusTransaction], statusResponse)) {
        _pendingResponses.remove(statusTransaction);
      }
    }
  }

  Future<R1DecodedFrame?> _queryFirmwareStatus({
    required String label,
    required Uint8List Function({required int serialId}) command,
  }) async {
    final transaction = _nextTransactionId();
    final response = Completer<R1DecodedFrame>();
    _pendingResponses[transaction] = response;
    try {
      await _write(_write2 ?? _write1, command(serialId: transaction));
      _log('R1 $label', 'Read requested (transaction $transaction)');
      final result = await response.future.timeout(const Duration(seconds: 2));
      final payload = result.data.isEmpty
          ? 'no payload'
          : hexOf(result.data, maxBytes: result.data.length);
      _log(
        'R1 $label',
        '${result.statusType}/${result.statusMethod}/${result.statusAck} • '
            '$payload',
        isError: result.statusAck != 'ok',
      );
      return result;
    } on TimeoutException {
      _log('R1 $label', 'No acknowledgement from firmware');
      return null;
    } finally {
      if (identical(_pendingResponses[transaction], response)) {
        _pendingResponses.remove(transaction);
      }
    }
  }

  Future<void> _waitForBond() async {
    if (!Platform.isAndroid) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return;
    }
    final address = deviceId;
    if (address == null) {
      return;
    }

    const bondNone = 10;
    const bondBonding = 11;
    const bondBonded = 12;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var sawBonding = false;
    var pairingPromptLogged = false;
    while (DateTime.now().isBefore(deadline)) {
      int? bondState;
      try {
        bondState = await _bondChannel.invokeMethod<int>('bondState', {
          'address': address,
        });
      } on PlatformException catch (error) {
        _log('R1 pairing', 'Could not read Android bond state: $error');
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }

      if (bondState == bondBonded) {
        _log('R1 pairing', 'Android LE bond established');
        return;
      }
      if (bondState == bondBonding) {
        sawBonding = true;
        if (!pairingPromptLogged) {
          pairingPromptLogged = true;
          _log(
            'R1 pairing',
            'Confirm “Pair” in the Android Bluetooth pairing request',
          );
        }
      } else if (bondState == bondNone && sawBonding) {
        throw const R1PairingException();
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const R1PairingException();
  }

  Future<void> reinitialize() async {
    if (!isConnected) {
      throw StateError('Connect the R1 first.');
    }
    await _startOfficialSession();
  }

  Future<QualifiedCharacteristic?> _findOptionalBattery(String deviceId) async {
    try {
      final services = await _ble.getDiscoveredServices(deviceId);
      final batteryService = Uuid.parse(R1Ids.batteryService);
      final batteryLevel = Uuid.parse(R1Ids.batteryLevel);
      final available = services.any(
        (service) =>
            service.id.expanded == batteryService.expanded &&
            service.characteristics.any(
              (characteristic) =>
                  characteristic.id.expanded == batteryLevel.expanded,
            ),
      );
      if (available) {
        return _characteristic(
          deviceId,
          R1Ids.batteryService,
          R1Ids.batteryLevel,
        );
      }
      _log(
        'R1 battery',
        'This ring firmware does not expose the optional standard battery '
            'characteristic.',
      );
    } catch (error) {
      _log('R1 battery', 'Optional characteristic discovery failed: $error');
    }
    return null;
  }

  QualifiedCharacteristic _characteristic(
    String deviceId,
    String service,
    String characteristic,
  ) {
    return QualifiedCharacteristic(
      serviceId: Uuid.parse(service),
      characteristicId: Uuid.parse(characteristic),
      deviceId: deviceId,
    );
  }

  void _subscribe(QualifiedCharacteristic characteristic, String source) {
    final subscription = _ble
        .subscribeToCharacteristic(characteristic)
        .listen(
          (value) => _handleNotification(Uint8List.fromList(value), source),
          onError: (Object error) {
            _log('R1 $source', 'Notification error: $error', isError: true);
          },
        );
    _notificationSubscriptions.add(subscription);
  }

  Future<void> _write(
    QualifiedCharacteristic? characteristic,
    List<int> value,
  ) async {
    if (characteristic == null) {
      throw StateError('R1 write characteristic is unavailable');
    }
    await _ble.writeCharacteristicWithoutResponse(characteristic, value: value);
    _log(
      'R1 TX',
      '${characteristic.characteristicId} • ${value.length} B • '
          '${hexOf(value, maxBytes: value.length)}',
    );
  }

  Future<void> sendRaw(Uint8List value, {bool secondary = true}) async {
    if (!isConnected) {
      throw StateError('Connect the R1 first.');
    }
    await _write(secondary ? (_write2 ?? _write1) : _write1, value);
    _log('R1 raw TX', hexOf(value));
  }

  /// Starts the R1 -> G2 Tri-Sync handoff using the production command model.
  /// Current Android BLE device IDs are MAC addresses; iOS exposes opaque UUIDs
  /// and needs the hardware MAC from manufacturer data instead.
  Future<void> startGlassesHandoff(String glassesMac) async {
    if (!isConnected) {
      throw StateError('Connect the R1 first.');
    }
    await _sendGlassesHandoff(glassesMac);
  }

  Future<void> _sendGlassesHandoff(String glassesMac) async {
    final mac = _parseMac(glassesMac);
    if (mac == null) {
      throw FormatException('Invalid G2 MAC address: $glassesMac');
    }
    final transactionId = _nextTransactionId();
    final frame = R1Protocol.advStart(glassesMac: mac, serialId: transactionId);
    final response = Completer<R1DecodedFrame>();
    _pendingResponses[transactionId] = response;
    handoffStatus =
        'waiting for R1 advStart acknowledgement (transaction $transactionId)';
    handoffAt = DateTime.now();
    _onChanged();
    try {
      await _write(_write2 ?? _write1, frame);
      _log(
        'R1 Tri-Sync',
        'Framed advStart sent for right-lens MAC $glassesMac '
            '(transaction $transactionId); waiting for firmware result',
      );
      final result = await response.future.timeout(const Duration(seconds: 4));
      if (!result.transferCrcValid) {
        handoffStatus =
            'invalid R1 advStart response checksum '
            '(${result.statusType}/${result.statusMethod}/${result.statusAck})';
        handoffAt = DateTime.now();
        _onChanged();
        throw StateError(handoffStatus!);
      }
      if (result.statusAck == 'ok') {
        handoffStatus = 'R1 accepted G2 handoff for $glassesMac';
      } else {
        // A repeated advStart can fail while a previously established
        // controller relationship continues forwarding source=2 gestures.
        handoffStatus =
            'R1 returned ${result.statusAck} to repeated advStart; '
            'an existing Tri-Sync link may still be active';
      }
      handoffAt = DateTime.now();
      _onChanged();
      _log('R1 Tri-Sync', handoffStatus!, isError: result.statusAck != 'ok');
    } on TimeoutException {
      handoffStatus =
          'timed out waiting for R1 advStart acknowledgement '
          '(transaction $transactionId)';
      handoffAt = DateTime.now();
      _onChanged();
      _log('R1 Tri-Sync', handoffStatus!, isError: true);
      rethrow;
    } finally {
      if (identical(_pendingResponses[transactionId], response)) {
        _pendingResponses.remove(transactionId);
      }
    }
  }

  int _nextTransactionId() {
    _transactionId = (_transactionId + 1) & 0xff;
    return _transactionId;
  }

  void _handleNotification(Uint8List data, String source) {
    if (data.isEmpty) {
      return;
    }
    _recordResponse(data, source);
    _decodeResponse(data, source);
  }

  void _recordResponse(Uint8List data, String source) {
    receivedPackets++;
    receivedBytes += data.length;
    lastResponseHex = hexOf(data, maxBytes: data.length);
    lastResponseSource = source;
    lastResponseAt = DateTime.now();
    _onChanged();
    _log('R1 RX', '$source • ${data.length} B • $lastResponseHex');
  }

  void _decodeResponse(Uint8List data, String source) {
    final frame = R1Protocol.decode(data);
    if (frame != null) {
      final payload = frame.data.isEmpty
          ? 'none'
          : hexOf(frame.data, maxBytes: frame.data.length);
      final summary =
          '${frame.commandName}/${frame.moduleName}/${frame.subCommandName} • '
          '${frame.statusType}/${frame.statusMethod}/${frame.statusAck} • '
          '${frame.data.length} B';
      lastProtocolSummary = summary;
      final pending = _pendingResponses[frame.serialId];
      if (frame.statusType == 'ack' &&
          pending != null &&
          !pending.isCompleted) {
        pending.complete(frame);
      }
      _log(
        'R1 protocol RX',
        '$source • serial=${frame.serialId} • '
            'cmd=${frame.commandName}(${frame.command}) '
            'module=${frame.moduleName}(${frame.module}) '
            'sub=${frame.subCommandName}(${frame.subCommand}) • '
            '${frame.statusType}/${frame.statusMethod}/${frame.statusAck} • '
            'crc=outer-${frame.transferCrcValid ? 'ok' : 'bad'}/'
            'model-${frame.modelCrcValid ? 'ok' : 'firmware-variant'} • '
            'data=$payload',
        // Production R1 acknowledgements use a different inner-model CRC
        // variant than commands, but their outer transfer CRC is valid.
        isError: !frame.transferCrcValid || frame.statusAck != 'ok',
      );
      if (frame.statusType == 'notify') {
        unsolicitedPackets++;
        final ascii = _printableAsciiRuns(frame.data);
        lastFirmwareEvent =
            '${frame.commandName}/${frame.subCommandName} • '
            '${frame.data.length} B';
        lastFirmwareAscii = ascii.isEmpty ? null : ascii.join(' | ');
        lastFirmwareEventAt = DateTime.now();
        _onChanged();
        _log(
          'R1 firmware event',
          '$lastFirmwareEvent'
              '${lastFirmwareAscii == null ? '' : ' • ASCII="$lastFirmwareAscii"'} • '
              'unsolicited protocol data, not a decoded touch gesture',
        );
      }
      if (frame.command == 1 && frame.subCommand == 6) {
        lastTouchStatus =
            '${frame.statusType}/${frame.statusMethod}/${frame.statusAck} • '
            '${frame.data.isEmpty ? 'no payload' : payload}';
        _onChanged();
        _log(
          'R1 touch status',
          '$lastTouchStatus • raw status only; no gesture mapping assumed',
        );
      }
      final deviceStatusBattery = decodeR1DeviceStatusBattery(frame);
      if (deviceStatusBattery != null) {
        batteryLevel = deviceStatusBattery;
        _onChanged();
        _log(
          'R1 battery',
          '$batteryLevel% · proprietary device-status response',
        );
      }
      if (frame.command == 1 &&
          frame.subCommand == 10 &&
          frame.statusType == 'ack' &&
          frame.statusAck != 'ok') {
        handoffStatus =
            'rejected by R1 firmware: advStart ${frame.statusAck} '
            '(data=$payload)';
        handoffAt = DateTime.now();
        _onChanged();
        _log(
          'R1 Tri-Sync',
          '$handoffStatus. The new handoff request was not accepted; an '
              'existing Tri-Sync link may still forward source=2 gestures '
              'through G2/EvenHub.',
          isError: true,
        );
      }
      return;
    }
    if (data.length >= 3 && data[0] == 0xff) {
      final gesture = switch (data[1]) {
        0x03 => 'hold',
        0x04 when data[2] == 0x01 => 'single_tap',
        0x04 when data[2] == 0x02 => 'double_tap',
        0x05 when data[2] < 0x80 => 'swipe_up',
        0x05 => 'swipe_down',
        _ => null,
      };
      if (gesture != null) {
        lastGesture = gesture;
        lastGestureAt = DateTime.now();
        _onChanged();
        _log('R1 gesture', gesture);
        return;
      }
    }
    if (data.length == 2 && data[0] <= 100) {
      batteryLevel = data[0];
      _onChanged();
      _log('R1 battery', '$batteryLevel%');
      return;
    }
    if (data.length > 3) {
      final marker = data.indexOf(0xff);
      if (marker >= 0 && marker + 2 < data.length) {
        _decodeResponse(
          Uint8List.fromList(data.sublist(marker, marker + 3)),
          '$source/embedded',
        );
        return;
      }
    }
    unclassifiedPackets++;
    _onChanged();
    _log(
      'R1 unclassified RX',
      '$source • ${data.length} B • no known framed, gesture, or battery '
          'decoder matched • ${hexOf(data, maxBytes: data.length)}',
    );
  }

  List<String> _printableAsciiRuns(Uint8List data) {
    final runs = <String>[];
    final current = StringBuffer();
    void flush() {
      if (current.length >= 4) {
        runs.add(current.toString());
      }
      current.clear();
    }

    for (final byte in data) {
      if (byte >= 0x20 && byte <= 0x7e) {
        current.writeCharCode(byte);
      } else {
        flush();
      }
    }
    flush();
    return runs;
  }

  void _startBatteryPolling() {
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_readBattery());
    });
  }

  Future<void> _readBattery() async {
    final battery = _battery;
    if (battery == null) {
      return;
    }
    try {
      final value = await _ble.readCharacteristic(battery);
      if (value.isNotEmpty) {
        final bytes = Uint8List.fromList(value);
        _recordResponse(bytes, 'battery/read');
        if (bytes[0] <= 100) {
          batteryLevel = bytes[0];
          _log('R1 battery', '$batteryLevel%');
        }
        _onChanged();
      }
    } catch (error) {
      _log('R1 battery', 'Read failed: $error');
    }
  }

  void _handleUnexpectedDisconnect() {
    if (_manualDisconnect) {
      return;
    }
    state = LinkState.reconnecting;
    _onChanged();
    _log('R1', 'Link dropped; retrying in 3 seconds', isError: true);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _target == null || _reconnectTimer != null) {
      return;
    }
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _reconnectTimer = null;
      final target = _target;
      if (target != null && !_manualDisconnect) {
        unawaited(
          connect(target, glassesMac: _setupGlassesMac).catchError((Object _) {
            // A failed setup stays stopped for explicit user recovery.
          }),
        );
      }
    });
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _teardown();
    state = LinkState.disconnected;
    _onChanged();
    _log('R1', 'Disconnected');
  }

  Future<void> _teardown() async {
    _batteryTimer?.cancel();
    _batteryTimer = null;
    for (final subscription in _notificationSubscriptions) {
      await subscription.cancel();
    }
    _notificationSubscriptions.clear();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _write1 = null;
    _write2 = null;
    _battery = null;
    for (final response in _pendingResponses.values) {
      if (!response.isCompleted) {
        response.completeError(StateError('R1 connection closed'));
      }
    }
    _pendingResponses.clear();
  }

  Future<void> dispose() async {
    await disconnect();
    _target = null;
  }

  Uint8List? _parseMac(String value) {
    final compact = value.replaceAll(':', '').replaceAll('-', '');
    if (!RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(compact)) {
      return null;
    }
    return Uint8List.fromList(<int>[
      for (var offset = 0; offset < 12; offset += 2)
        int.parse(compact.substring(offset, offset + 2), radix: 16),
    ]);
  }
}
