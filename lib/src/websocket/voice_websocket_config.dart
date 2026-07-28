import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum VoiceWebSocketAuthHeader {
  authorizationBearer,
  voiceApiToken;

  String get serializedName => switch (this) {
    authorizationBearer => 'authorizationBearer',
    voiceApiToken => 'xVoiceApiToken',
  };

  static VoiceWebSocketAuthHeader parse(Object? value) {
    return switch (value) {
      'authorizationBearer' => authorizationBearer,
      'xVoiceApiToken' => voiceApiToken,
      _ => throw const FormatException(
        'Authentication header must be Authorization bearer or '
        'X-Voice-Api-Token.',
      ),
    };
  }
}

final class VoiceWebSocketConfig {
  const VoiceWebSocketConfig({
    required this.host,
    required this.port,
    required this.secret,
    required this.authHeader,
    required this.agentNames,
    required this.useLegacyMessageShape,
  });

  static const int schemaVersion = 1;
  static const int maximumSecretCharacters = 512;
  static const int maximumAgentNames = 32;
  static const int maximumAgentNameCharacters = 64;
  static const String websocketPath = '/ws';

  static const defaults = VoiceWebSocketConfig(
    host: '127.0.0.1',
    port: 8787,
    secret: '',
    authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
    agentNames: <String>[],
    useLegacyMessageShape: false,
  );

  final String host;
  final int port;
  final String secret;
  final VoiceWebSocketAuthHeader authHeader;
  final List<String> agentNames;
  final bool useLegacyMessageShape;

  bool get isConfigured => secret.isNotEmpty && agentNames.isNotEmpty;

  Uri get uri => Uri(scheme: 'ws', host: host, port: port, path: websocketPath);

  Map<String, Object> get upgradeHeaders => switch (authHeader) {
    VoiceWebSocketAuthHeader.authorizationBearer => <String, Object>{
      HttpHeaders.authorizationHeader: 'Bearer $secret',
    },
    VoiceWebSocketAuthHeader.voiceApiToken => <String, Object>{
      'X-Voice-Api-Token': secret,
    },
  };

  VoiceWebSocketConfig copyWith({
    String? host,
    int? port,
    String? secret,
    VoiceWebSocketAuthHeader? authHeader,
    List<String>? agentNames,
    bool? useLegacyMessageShape,
  }) => VoiceWebSocketConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    secret: secret ?? this.secret,
    authHeader: authHeader ?? this.authHeader,
    agentNames: agentNames ?? this.agentNames,
    useLegacyMessageShape: useLegacyMessageShape ?? this.useLegacyMessageShape,
  );

  Map<String, Object> toJson() => <String, Object>{
    'version': schemaVersion,
    'voiceWebSocket': <String, Object>{
      'host': host,
      'port': port,
      'path': websocketPath,
      'secret': secret,
      'authHeader': authHeader.serializedName,
      'agentNames': agentNames,
      'useLegacyMessageShape': useLegacyMessageShape,
    },
  };

  static VoiceWebSocketConfig fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
        'voice_websocket.json must contain a JSON object.',
      );
    }
    if (value['version'] != schemaVersion) {
      throw const FormatException('voice_websocket.json version must be 1.');
    }
    final socket = value['voiceWebSocket'];
    if (socket is! Map<String, dynamic>) {
      throw const FormatException(
        'voice_websocket.json must contain voiceWebSocket settings.',
      );
    }
    final host = socket['host'];
    final port = socket['port'];
    final path = socket['path'];
    final secret = socket['secret'];
    final authHeader = socket['authHeader'];
    final agentNames = socket['agentNames'];
    final legacy = socket['useLegacyMessageShape'];
    if (host is! String ||
        port is! int ||
        path is! String ||
        secret is! String ||
        agentNames is! List<dynamic> ||
        legacy is! bool) {
      throw const FormatException(
        'Voice WebSocket settings have invalid value types.',
      );
    }
    if (path != websocketPath) {
      throw const FormatException('The WebSocket path must be /ws.');
    }
    return validate(
      host: host,
      port: port,
      secret: secret,
      authHeader: VoiceWebSocketAuthHeader.parse(authHeader),
      agentNames: agentNames.map((value) {
        if (value is! String) {
          throw const FormatException('Every agent name must be text.');
        }
        return value;
      }),
      useLegacyMessageShape: legacy,
    );
  }

  static VoiceWebSocketConfig validate({
    required String host,
    required int port,
    required String secret,
    required VoiceWebSocketAuthHeader authHeader,
    required Iterable<String> agentNames,
    required bool useLegacyMessageShape,
  }) {
    final validatedHost = validateIpv4(host);
    if (port < 1 || port > 65535) {
      throw const FormatException('Port must be between 1 and 65535.');
    }
    final validatedSecret = validateSecret(secret);
    final validatedAgents = validateAgentNames(agentNames);
    return VoiceWebSocketConfig(
      host: validatedHost,
      port: port,
      secret: validatedSecret,
      authHeader: authHeader,
      agentNames: List<String>.unmodifiable(validatedAgents),
      useLegacyMessageShape: useLegacyMessageShape,
    );
  }

  static String validateIpv4(String value) {
    final trimmed = value.trim();
    final parts = trimmed.split('.');
    if (parts.length != 4) {
      throw const FormatException(
        'IP address must contain four numbers separated by dots.',
      );
    }
    for (final part in parts) {
      if (part.isEmpty || part.length > 3 || !RegExp(r'^\d+$').hasMatch(part)) {
        throw const FormatException('Enter a valid IPv4 address.');
      }
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) {
        throw const FormatException(
          'Each IP address number must be from 0 to 255.',
        );
      }
    }
    return parts.map((part) => int.parse(part)).join('.');
  }

  static String validateSecret(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Secret cannot be empty.');
    }
    if (trimmed.length > maximumSecretCharacters) {
      throw const FormatException('Secret cannot exceed 512 characters.');
    }
    if (trimmed.contains('\r') || trimmed.contains('\n')) {
      throw const FormatException('Secret must fit on one line.');
    }
    for (final rune in trimmed.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        throw const FormatException(
          'Secret contains an unsupported control character.',
        );
      }
    }
    return trimmed;
  }

  static List<String> validateAgentNames(Iterable<String> values) {
    final result = <String>[];
    final normalized = <String>{};
    for (final value in values) {
      final name = value.trim();
      if (name.isEmpty) {
        continue;
      }
      if (name.length > maximumAgentNameCharacters) {
        throw const FormatException(
          'Each agent name must be 64 characters or fewer.',
        );
      }
      for (final rune in name.runes) {
        if (rune < 0x20 || rune == 0x7f) {
          throw const FormatException(
            'Agent names contain an unsupported control character.',
          );
        }
      }
      if (normalized.add(name.toLowerCase())) {
        result.add(name);
      }
    }
    if (result.isEmpty) {
      throw const FormatException('Add at least one agent name.');
    }
    if (result.length > maximumAgentNames) {
      throw const FormatException('Add no more than 32 agent names.');
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceWebSocketConfig &&
      other.host == host &&
      other.port == port &&
      other.secret == secret &&
      other.authHeader == authHeader &&
      listEquals(other.agentNames, agentNames) &&
      other.useLegacyMessageShape == useLegacyMessageShape;

  @override
  int get hashCode => Object.hash(
    host,
    port,
    secret,
    authHeader,
    Object.hashAll(agentNames),
    useLegacyMessageShape,
  );
}

final class VoiceWebSocketConfigStore extends ChangeNotifier {
  VoiceWebSocketConfigStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  final Future<Directory> Function() _supportDirectory;
  File? _file;

  VoiceWebSocketConfig config = VoiceWebSocketConfig.defaults;
  String? validationError;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    final workbench = Directory('${support.path}/workbench');
    await workbench.create(recursive: true);
    _file = File('${workbench.path}/voice_websocket.json');
    if (!await _file!.exists()) {
      return;
    }
    await reload();
  }

  Future<VoiceWebSocketConfig> reload() async {
    final file = _file;
    if (file == null) {
      throw StateError('Voice WebSocket configuration is not initialized.');
    }
    try {
      final loaded = VoiceWebSocketConfig.fromJson(
        jsonDecode(await file.readAsString()),
      );
      final changed = loaded != config || validationError != null;
      config = loaded;
      validationError = null;
      if (changed) {
        notifyListeners();
      }
    } on Object catch (error) {
      final message = _oneLine(error);
      if (validationError != message) {
        validationError = message;
        notifyListeners();
      }
    }
    return config;
  }

  Future<void> save(VoiceWebSocketConfig value) async {
    final validated = VoiceWebSocketConfig.validate(
      host: value.host,
      port: value.port,
      secret: value.secret,
      authHeader: value.authHeader,
      agentNames: value.agentNames,
      useLegacyMessageShape: value.useLegacyMessageShape,
    );
    final file = _file;
    if (file == null) {
      throw StateError('Voice WebSocket configuration is not initialized.');
    }
    final partial = File('${file.path}.part');
    final formatted = const JsonEncoder.withIndent(
      '  ',
    ).convert(validated.toJson());
    await partial.writeAsString('$formatted\n', flush: true);
    await partial.rename(file.path);
    config = validated;
    validationError = null;
    notifyListeners();
  }

  static String _oneLine(Object value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}
