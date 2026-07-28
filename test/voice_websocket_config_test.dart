import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-voice-websocket-config-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test(
    'validates and atomically saves app-private connection settings',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      addTearDown(store.dispose);
      await store.initialize();
      final config = VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 8787,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.voiceApiToken,
        agentNames: const <String>['Agent One', 'Agent Two', 'agent one'],
        useLegacyMessageShape: false,
      );

      await store.save(config);

      final file = File('${temp.path}/workbench/voice_websocket.json');
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final socket = decoded['voiceWebSocket'] as Map<String, dynamic>;
      expect(socket['host'], '127.0.0.1');
      expect(socket['port'], 8787);
      expect(socket['path'], '/ws');
      expect(socket['secret'], 'example-secret');
      expect(socket['authHeader'], 'xVoiceApiToken');
      expect(socket['agentNames'], <String>['Agent One', 'Agent Two']);
      expect(File('${file.path}.part').existsSync(), isFalse);
    },
  );

  test(
    'keeps the last valid configuration after an invalid external edit',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      addTearDown(store.dispose);
      await store.initialize();
      final valid = VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 8787,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
        useLegacyMessageShape: false,
      );
      await store.save(valid);
      final file = File('${temp.path}/workbench/voice_websocket.json');
      await file.writeAsString(
        '{"version":1,"voiceWebSocket":{"host":"999.1.1.1"}}',
        flush: true,
      );

      final loaded = await store.reload();

      expect(loaded, valid);
      expect(store.validationError, isNotNull);
    },
  );

  test('rejects unsafe addresses, ports, secrets, and empty agent lists', () {
    expect(
      () => VoiceWebSocketConfig.validateIpv4('192.168.1'),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validateIpv4('256.1.1.1'),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validateSecret('line\nbreak'),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 0,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
        useLegacyMessageShape: false,
      ),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validateAgentNames(const <String>[' ', '']),
      throwsFormatException,
    );
  });

  test('builds only the selected upgrade authentication header', () {
    final bearer = VoiceWebSocketConfig.validate(
      host: '127.0.0.1',
      port: 8787,
      secret: 'example-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['Agent One'],
      useLegacyMessageShape: false,
    );
    final token = bearer.copyWith(
      authHeader: VoiceWebSocketAuthHeader.voiceApiToken,
    );

    expect(bearer.upgradeHeaders, <String, Object>{
      HttpHeaders.authorizationHeader: 'Bearer example-secret',
    });
    expect(token.upgradeHeaders, <String, Object>{
      'X-Voice-Api-Token': 'example-secret',
    });
  });
}
