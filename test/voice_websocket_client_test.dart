import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late List<WebSocket> serverSockets;
  late List<Map<String, dynamic>> received;
  late List<String?> authorizationHeaders;
  late Completer<Map<String, dynamic>> resumed;
  late bool closeFirstModernRequestBeforeAcknowledgement;
  late int closedModernRequestCount;
  late int modernRouteCount;
  late Map<String, Map<String, Object?>> acceptedByRequestId;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync(
      'workbench-voice-websocket-client-test-',
    );
    serverSockets = <WebSocket>[];
    received = <Map<String, dynamic>>[];
    authorizationHeaders = <String?>[];
    resumed = Completer<Map<String, dynamic>>();
    closeFirstModernRequestBeforeAcknowledgement = false;
    closedModernRequestCount = 0;
    modernRouteCount = 0;
    acceptedByRequestId = <String, Map<String, Object?>>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      authorizationHeaders.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      final socket = await WebSocketTransformer.upgrade(request);
      serverSockets.add(socket);
      socket.listen((data) async {
        if (data is! String) {
          return;
        }
        final payload = jsonDecode(data) as Map<String, dynamic>;
        received.add(payload);
        if (payload['type'] == 'message.send') {
          final requestId = payload['request_id'] as String;
          final previous = acceptedByRequestId[requestId];
          if (previous != null) {
            socket.add(jsonEncode(previous));
            return;
          }
          if (closeFirstModernRequestBeforeAcknowledgement &&
              closedModernRequestCount == 0) {
            closedModernRequestCount++;
            modernRouteCount++;
            acceptedByRequestId[requestId] = _acceptedPayload(payload);
            await socket.close();
            return;
          }
          modernRouteCount++;
          final response = _acceptedPayload(payload);
          acceptedByRequestId[requestId] = response;
          socket.add(jsonEncode(response));
        } else if (payload['type'] == 'connection.resume' &&
            !resumed.isCompleted) {
          resumed.complete(payload);
        }
      });
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'connection.ready',
          'version': 1,
          'server_session_id': 'example-session',
          'agents': <String>['Agent One'],
          'agent_controls': <String>['Agent One clear terminal'],
          'session_controls': <String>['Session terminate'],
          'websocket_path': '/ws',
        }),
      );
    });
  });

  tearDown(() async {
    for (final socket in serverSockets) {
      await socket.close();
    }
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  test('authenticates, waits for ready and acknowledgement, displays inbound, '
      'then resumes after reconnect', () async {
    final inbound = <String>[];
    final store = VoiceWebSocketConfigStore(supportDirectory: () async => temp);
    final client = VoiceWebSocketClient(
      configStore: store,
      reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
      readyTimeout: const Duration(seconds: 1),
      acknowledgementTimeout: const Duration(seconds: 1),
      onInboundMessage: (message) async => inbound.add(message),
    );
    addTearDown(client.close);
    await client.initialize();
    final config = VoiceWebSocketConfig.validate(
      host: '127.0.0.1',
      port: server.port,
      secret: 'example-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['Agent One', 'Agent Two', 'Flux'],
      useLegacyMessageShape: false,
    );
    await client.saveConfig(config);
    await _waitUntil(() => client.isReady);

    expect(authorizationHeaders.single, 'Bearer example-secret');
    expect(received, isEmpty, reason: 'No client hello is allowed.');
    expect(client.serverAgents, <String>['Agent One']);
    expect(client.agentControls, <String>['Agent One clear terminal']);
    expect(client.sessionControls, <String>['Session terminate']);

    final route = client.routeForTranscript(
      'Agent One, pull the latest changes',
    );
    expect(route?.agent, 'Agent One');
    expect(route?.message, 'pull the latest changes');
    final conversationalRoute = client.routeForTranscript(
      'Hey Flux, pull the latestest changes',
    );
    expect(conversationalRoute?.agent, 'Flux');
    expect(
      conversationalRoute?.message,
      'Hey Flux, pull the latestest changes',
      reason:
          'An agent named in conversational context keeps the full request.',
    );
    expect(
      client.routeForTranscript('An agent oneness task'),
      isNull,
      reason: 'Agent names must match a complete phrase.',
    );

    final sent = await client.sendTranscript(
      'Agent One, pull the latest changes',
    );
    expect(sent, isTrue);
    final send = received.single;
    expect(send['type'], 'message.send');
    expect(send['request_id'], isNotEmpty);
    expect(send['agent'], 'Agent One');
    expect(send['message'], 'pull the latest changes');

    final rejected = await client.sendAgentMessage(
      agent: 'Agent Two',
      message: 'run a rejected fixture request',
    );
    expect(rejected, isFalse);

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.progress',
        'event_id': 42,
        'agent': 'Agent One',
        'request_id': 'example-request',
        'payload': <String, Object>{
          'agent': 'Agent One',
          'summary': 'The requested task is still running.',
          'detail_lines': <String>['Private detail is not the summary.'],
          'phase': 'in_progress',
          'is_final': false,
        },
      }),
    );
    await _waitUntil(() => inbound.isNotEmpty);
    expect(inbound.single, 'Agent One: The requested task is still running.');

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.completed',
        'event_id': 43,
        'agent': 'Agent One',
        'request_id': 'example-request',
        'payload': <String, Object>{
          'agent': 'Agent One',
          'completion_message': 'The requested task completed.',
          'phase': 'final',
          'is_final': true,
        },
      }),
    );
    await _waitUntil(() => inbound.length == 2);
    expect(inbound.last, 'Agent One: The requested task completed.');
    await _waitUntil(
      () =>
          received.where((payload) => payload['type'] == 'event.ack').length ==
          2,
    );
    expect(
      received
          .where((payload) => payload['type'] == 'event.ack')
          .map((payload) => payload['event_id']),
      <int>[42, 43],
    );

    await serverSockets.single.close();
    await _waitUntil(() => serverSockets.length == 2);
    final resume = await resumed.future.timeout(const Duration(seconds: 2));
    expect(resume, <String, dynamic>{
      'type': 'connection.resume',
      'resume_after_event_id': 43,
    });
  });

  test(
    'does not acknowledge an inbound event when durable delivery fails',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
        onInboundMessage: (_) async {
          throw FileSystemException('Fixture persistence failure');
        },
      );
      addTearDown(client.close);
      await client.initialize();
      await client.saveConfig(
        VoiceWebSocketConfig.validate(
          host: '127.0.0.1',
          port: server.port,
          secret: 'example-secret',
          authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
          agentNames: const <String>['Agent One'],
          useLegacyMessageShape: false,
        ),
      );
      await _waitUntil(() => client.isReady);

      serverSockets.single.add(
        jsonEncode(<String, Object>{
          'type': 'message.completed',
          'event_id': 91,
          'agent': 'Agent One',
          'payload': <String, Object>{
            'summary': 'A response that could not be stored.',
          },
        }),
      );

      await _waitUntil(() => serverSockets.length == 2);
      expect(
        received.where(
          (payload) =>
              payload['type'] == 'event.ack' && payload['event_id'] == 91,
        ),
        isEmpty,
      );
      expect(
        received.where((payload) => payload['type'] == 'connection.resume'),
        isEmpty,
      );
    },
  );

  test(
    'sends the exact legacy agent and message shape when selected',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
      );
      addTearDown(client.close);
      await client.initialize();
      await client.saveConfig(
        VoiceWebSocketConfig.validate(
          host: '127.0.0.1',
          port: server.port,
          secret: 'example-secret',
          authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
          agentNames: const <String>['Agent One'],
          useLegacyMessageShape: true,
        ),
      );
      await _waitUntil(() => client.isReady);

      final sent = await client.sendTranscript('Agent One, run the check');
      await _waitUntil(() => received.isNotEmpty);

      expect(sent, isTrue);
      expect(received.single, <String, dynamic>{
        'agent': 'Agent One',
        'message': 'run the check',
      });
    },
  );

  test(
    'reconnects and reuses the request id when acknowledgement is lost',
    () async {
      closeFirstModernRequestBeforeAcknowledgement = true;
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
        acknowledgementTimeout: const Duration(seconds: 1),
      );
      addTearDown(client.close);
      await client.initialize();
      await client.saveConfig(
        VoiceWebSocketConfig.validate(
          host: '127.0.0.1',
          port: server.port,
          secret: 'example-secret',
          authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
          agentNames: const <String>['Flux'],
          useLegacyMessageShape: false,
        ),
      );
      await _waitUntil(() => client.isReady);

      final sent = await client.sendAgentMessage(
        agent: 'Flux',
        message: 'pull the latest changes',
      );
      final sends = received
          .where((payload) => payload['type'] == 'message.send')
          .toList(growable: false);

      expect(sent, isTrue);
      expect(serverSockets, hasLength(2));
      expect(sends, hasLength(2));
      expect(sends[0]['request_id'], isNotEmpty);
      expect(sends[1]['request_id'], sends[0]['request_id']);
      expect(sends[1]['agent'], 'Flux');
      expect(sends[1]['message'], 'pull the latest changes');
      expect(modernRouteCount, 1);
    },
  );
}

Map<String, Object?> _acceptedPayload(Map<String, dynamic> payload) {
  final accepted = payload['agent'] != 'Agent Two';
  return <String, Object?>{
    'type': 'message.accepted',
    'version': 1,
    'request_id': payload['request_id'],
    'ok': accepted,
    'result': <String, Object?>{
      'ok': accepted,
      'agent': payload['agent'],
      'message': payload['message'],
      'focused': accepted,
      'sent': accepted,
    },
  };
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
