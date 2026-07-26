import 'dart:typed_data';

/// Production framing used by the Even Realities R1 command service.
///
/// The ring does not accept the public enum ordinals as a three-byte header.
/// Commands use an inner 12-byte model header protected by CRC-16, followed by
/// an outer transfer index and CRC-32C checksum.
abstract final class R1Protocol {
  static const int _version = 100;
  static const int _systemCommand = 1;
  static const int _moduleVersion = 100;
  static const int _systemModule = 0;
  static const int _deviceStatusSubCommand = 1;
  static const int _systemTimeSubCommand = 5;
  static const int _touchStatusSubCommand = 6;
  static const int _touchSwitchSubCommand = 7;
  static const int _pairAuthSubCommand = 8;
  static const int _advStartSubCommand = 10;
  static const int _modelHeaderLength = 12;
  static const int _crc32cPolynomial = 0x1edc6f41;

  /// Authenticates this phone as the active R1 command client.
  ///
  /// The production app sends this immediately after connecting. Without it,
  /// GATT writes succeed but the ring remains silent.
  static Uint8List pairAuth({required int serialId}) {
    return _command(
      data: Uint8List.fromList(const <int>[1]),
      serialId: serialId,
      subCommand: _pairAuthSubCommand,
    );
  }

  /// Requests the ring's current device-status payload.
  static Uint8List deviceStatus({required int serialId}) {
    return _command(
      data: Uint8List(0),
      serialId: serialId,
      subCommand: _deviceStatusSubCommand,
    );
  }

  /// Synchronizes the R1 clock using the production 12-byte system-time model.
  static Uint8List systemTime({required DateTime time, required int serialId}) {
    final data = Uint8List(12);
    final bytes = ByteData.sublistView(data);
    bytes.setInt16(0, time.timeZoneOffset.inMinutes, Endian.little);
    bytes.setUint32(
      2,
      time.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
      Endian.little,
    );
    return _command(
      data: data,
      serialId: serialId,
      status: 0x02, // notify + set + OK
      subCommand: _systemTimeSubCommand,
    );
  }

  /// Enables or disables TouchPad reporting on the direct phone GATT session.
  ///
  /// Production firmware exposes this as system/touch_switch (sub-command 7).
  /// This does not select a G2 target; unlike [advStart], it is appropriate for
  /// a phone-owned diagnostic/input session.
  static Uint8List touchSwitch({required bool enabled, required int serialId}) {
    return _command(
      data: Uint8List.fromList(<int>[enabled ? 1 : 0]),
      serialId: serialId,
      subCommand: _touchSwitchSubCommand,
    );
  }

  /// Requests the current TouchPad state from the R1.
  static Uint8List touchStatus({required int serialId}) {
    return _command(
      data: Uint8List(0),
      serialId: serialId,
      subCommand: _touchStatusSubCommand,
    );
  }

  /// Builds the official `advStart` command that tells the R1 which glasses
  /// should receive its Tri-Sync gesture events.
  static Uint8List advStart({
    required Uint8List glassesMac,
    required int serialId,
  }) {
    if (glassesMac.length != 6) {
      throw ArgumentError.value(
        glassesMac.length,
        'glassesMac',
        'An R1 advStart command requires exactly 6 MAC bytes.',
      );
    }
    if (serialId < 0 || serialId > 0xff) {
      throw RangeError.range(serialId, 0, 0xff, 'serialId');
    }
    return _command(
      data: glassesMac,
      serialId: serialId,
      subCommand: _advStartSubCommand,
    );
  }

  static Uint8List _command({
    required Uint8List data,
    required int serialId,
    required int subCommand,
    int status = 0,
  }) {
    if (serialId < 0 || serialId > 0xffff) {
      throw RangeError.range(serialId, 0, 0xffff, 'serialId');
    }
    final model = Uint8List(_modelHeaderLength + data.length);
    final bytes = ByteData.sublistView(model);
    model[0] = _version;
    model[1] = _systemCommand;
    model[2] = _moduleVersion;
    bytes.setUint16(3, serialId, Endian.little);
    model[5] = status;
    model[6] = _systemModule;
    model[7] = subCommand;
    bytes.setUint16(8, model.length, Endian.little);
    model.setRange(_modelHeaderLength, model.length, data);

    // The checksum is calculated with its own two-byte field still zero.
    bytes.setUint16(10, crc16(model), Endian.little);

    final frame = Uint8List(1 + 4 + model.length);
    frame[0] = 0; // single transfer packet
    ByteData.sublistView(frame).setUint32(1, crc32c(model), Endian.little);
    frame.setRange(5, frame.length, model);
    return frame;
  }

  /// Decodes and validates a complete, single-packet R1 transfer.
  ///
  /// Returns `null` for legacy setup bytes and incomplete/multi-packet data.
  static R1DecodedFrame? decode(Uint8List frame) {
    if (frame.length < 5 + _modelHeaderLength) {
      return null;
    }
    final frameBytes = ByteData.sublistView(frame);
    final declaredLength = frameBytes.getUint16(5 + 8, Endian.little);
    if (declaredLength < _modelHeaderLength ||
        frame.length < 5 + declaredLength) {
      return null;
    }

    final model = Uint8List.fromList(frame.sublist(5, 5 + declaredLength));
    final modelBytes = ByteData.sublistView(model);
    final expectedTransferCrc = frameBytes.getUint32(1, Endian.little);
    final expectedModelCrc = modelBytes.getUint16(10, Endian.little);
    final modelForCrc = Uint8List.fromList(model);
    modelForCrc[10] = 0;
    modelForCrc[11] = 0;

    return R1DecodedFrame(
      transferIndex: frame[0],
      transferCrcValid: crc32c(model) == expectedTransferCrc,
      modelCrcValid: crc16(modelForCrc) == expectedModelCrc,
      version: model[0],
      command: model[1],
      moduleVersion: model[2],
      serialId: modelBytes.getUint16(3, Endian.little),
      status: model[5],
      module: model[6],
      subCommand: model[7],
      data: Uint8List.fromList(model.sublist(_modelHeaderLength)),
    );
  }

  /// CRC-16 variant used in the R1 model header (initial value `0xffff`).
  static int crc16(List<int> data) {
    var crc = 0xffff;
    for (final byte in data) {
      crc = ((crc >> 8) | ((crc & 0xff) << 8)) & 0xffff;
      crc ^= byte & 0xff;
      crc ^= (crc & 0xff) >> 4;
      crc ^= (crc << 12) & 0xffff;
      crc ^= ((crc & 0xff) << 5) & 0xffff;
      crc &= 0xffff;
    }
    return crc;
  }

  /// Non-reflected CRC-32C used by the R1 transfer wrapper.
  ///
  /// This intentionally starts at zero and has no final XOR, matching the
  /// current Even Realities Android implementation.
  static int crc32c(List<int> data) {
    var crc = 0;
    for (final byte in data) {
      crc ^= (byte & 0xff) << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc =
            ((crc << 1) ^ ((crc & 0x80000000) != 0 ? _crc32cPolynomial : 0)) &
            0xffffffff;
      }
    }
    return crc;
  }
}

final class R1DecodedFrame {
  const R1DecodedFrame({
    required this.transferIndex,
    required this.transferCrcValid,
    required this.modelCrcValid,
    required this.version,
    required this.command,
    required this.moduleVersion,
    required this.serialId,
    required this.status,
    required this.module,
    required this.subCommand,
    required this.data,
  });

  final int transferIndex;
  final bool transferCrcValid;
  final bool modelCrcValid;
  final int version;
  final int command;
  final int moduleVersion;
  final int serialId;
  final int status;
  final int module;
  final int subCommand;
  final Uint8List data;

  bool get checksumsValid => transferCrcValid && modelCrcValid;

  String get statusType => (status & 0x01) == 0 ? 'notify' : 'ack';

  String get statusMethod => (status & 0x02) == 0 ? 'get' : 'set';

  String get statusAck => switch ((status >> 2) & 0x03) {
    0 => 'ok',
    1 => 'error',
    2 => 'refuse',
    _ => 'not_supported',
  };

  String get commandName => switch (command) {
    1 => 'system',
    2 => 'heart_rate',
    3 => 'spo2',
    4 => 'temperature',
    5 => 'hrv',
    6 => 'activity',
    7 => 'sleep',
    8 => 'sport_run_control',
    9 => 'sport_run_data',
    10 => 'health_setting',
    _ => 'command_0x${command.toRadixString(16).padLeft(2, '0')}',
  };

  String get moduleName => switch (module) {
    0 => 'system',
    1 => 'health',
    2 => 'sport',
    3 => 'test',
    _ => 'module_0x${module.toRadixString(16).padLeft(2, '0')}',
  };

  String get subCommandName => switch (subCommand) {
    1 => 'device_status',
    2 => 'device_info',
    3 => 'wear_status',
    4 => 'user_info',
    5 => 'system_time',
    6 => 'touch_status',
    7 => 'touch_switch',
    8 => 'pair_auth',
    9 => 'ota_start',
    10 => 'adv_start',
    11 => 'algorithm_key_status',
    12 => 'set_algorithm_key',
    13 => 'health_settings_status',
    14 => 'system_settings_status',
    15 => 'device_serial_number',
    16 => 'nv_recover',
    17 => 'power_control',
    0xfc => 'packet_ack',
    0xfe => 'heartbeat',
    _ => '0x${subCommand.toRadixString(16).padLeft(2, '0')}',
  };
}

int? decodeR1DeviceStatusBattery(R1DecodedFrame frame) {
  if (frame.command != 1 ||
      frame.module != 0 ||
      frame.subCommand != 1 ||
      frame.statusType != 'ack' ||
      frame.statusAck != 'ok' ||
      frame.data.isEmpty ||
      frame.data[0] > 100) {
    return null;
  }
  return frame.data[0];
}
