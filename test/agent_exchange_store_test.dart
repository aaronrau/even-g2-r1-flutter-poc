import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/agent_exchange_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-agent-exchange-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test(
    'persists latest acknowledged command and correlated response',
    () async {
      final sent = File('${temp.path}/sent.message.txt')
        ..writeAsStringSync('Pike: validate synthetic fixture\n');
      final received = File('${temp.path}/received.message.txt')
        ..writeAsStringSync('Pike: synthetic result\n');
      final store = AgentExchangeStore(
        supportDirectory: () async => temp,
        now: () => DateTime.utc(2026, 1, 1),
      );
      await store.initialize();
      final id = await store.recordSent(
        agent: 'Pike',
        messagePath: sent.path,
        legacy: false,
        requestId: 'delivery-request',
      );
      expect(
        await store.attachResponse(
          responsePath: received.path,
          kind: 'progress',
          requestId: 'delivery-request',
          agent: 'Pike',
        ),
        id,
      );

      final reopened = AgentExchangeStore(supportDirectory: () async => temp);
      await reopened.initialize();
      final view = await reopened.viewById(id);
      expect(view?.message, 'validate synthetic fixture');
      expect(view?.response, 'Pike: synthetic result');
    },
  );

  test(
    'holds a fast summary response until request association is saved',
    () async {
      final sent = File('${temp.path}/sent.message.txt')
        ..writeAsStringSync('Pike: request update\n');
      final response = File('${temp.path}/received.message.txt')
        ..writeAsStringSync('Pike: ready\n');
      final store = AgentExchangeStore(supportDirectory: () async => temp);
      await store.initialize();
      final id = await store.recordSent(
        agent: 'Pike',
        messagePath: sent.path,
        legacy: false,
        requestId: 'delivery-request',
      );

      expect(
        await store.attachResponse(
          responsePath: response.path,
          kind: 'summary',
          requestId: 'summary-request',
          agent: 'Pike',
        ),
        isNull,
      );
      await store.associateSummary(
        exchangeId: id,
        requestId: 'summary-request',
      );

      expect((await store.viewById(id))?.response, 'Pike: ready');
    },
  );

  test('does not attach an unrelated same-agent modern event', () async {
    final sent = File('${temp.path}/sent.message.txt')
      ..writeAsStringSync('Pike: request update\n');
    final response = File('${temp.path}/received.message.txt')
      ..writeAsStringSync('Pike: unrelated\n');
    final store = AgentExchangeStore(supportDirectory: () async => temp);
    await store.initialize();
    final id = await store.recordSent(
      agent: 'Pike',
      messagePath: sent.path,
      legacy: false,
      requestId: 'expected-request',
    );
    await store.attachResponse(
      responsePath: response.path,
      kind: 'progress',
      requestId: 'different-request',
      agent: 'Pike',
    );

    expect((await store.viewById(id))?.response, isNull);
  });

  test(
    'imports only the newest pre-ledger message for each configured agent',
    () async {
      final older = File(
        '${temp.path}/workbench-websocket-20260101.sent.message.txt',
      )..writeAsStringSync('Pike: older request\n');
      final newest = File(
        '${temp.path}/workbench-websocket-20260102.sent.message.txt',
      )..writeAsStringSync('Pike: newest request\n');
      final other = File(
        '${temp.path}/workbench-websocket-20260103.sent.message.txt',
      )..writeAsStringSync('Agent Two: other request\n');
      older.setLastModifiedSync(DateTime.utc(2026, 1, 1));
      newest.setLastModifiedSync(DateTime.utc(2026, 1, 2));
      other.setLastModifiedSync(DateTime.utc(2026, 1, 3));
      final store = AgentExchangeStore(supportDirectory: () async => temp);
      await store.initialize();

      await store.importExistingSentMessages(
        paths: <String>[older.path, newest.path, other.path]..sort(),
        agents: const <String>['Pike', 'Agent Two'],
        legacy: false,
      );
      final views = await store.latestForAgents(const <String>[
        'Pike',
        'Agent Two',
      ]);

      expect(views, hasLength(2));
      expect(
        views.firstWhere((view) => view.agent == 'Pike').message,
        'newest request',
      );
      expect(
        views.firstWhere((view) => view.agent == 'Agent Two').message,
        'other request',
      );

      await store.clear();
      await store.importExistingSentMessages(
        paths: <String>[newest.path],
        agents: const <String>['Pike'],
        legacy: false,
      );
      expect(await store.latestForAgents(const <String>['Pike']), isEmpty);
    },
  );

  test('loads only the five newest exchanges for one selected agent', () async {
    var now = DateTime.utc(2026, 1, 1);
    final store = AgentExchangeStore(
      supportDirectory: () async => temp,
      now: () => now,
    );
    await store.initialize();
    for (var index = 0; index < 6; index++) {
      final sent = File('${temp.path}/pike-$index.sent.message.txt')
        ..writeAsStringSync('Pike: synthetic request $index\n');
      await store.recordSent(
        agent: 'Pike',
        messagePath: sent.path,
        legacy: false,
      );
      now = now.add(const Duration(minutes: 1));
    }
    final other = File('${temp.path}/other.sent.message.txt')
      ..writeAsStringSync('Agent Two: unrelated synthetic request\n');
    await store.recordSent(
      agent: 'Agent Two',
      messagePath: other.path,
      legacy: false,
    );

    final recent = await store.recentForAgent('pike');

    expect(recent, hasLength(5));
    expect(recent.map((exchange) => exchange.message), <String>[
      'synthetic request 5',
      'synthetic request 4',
      'synthetic request 3',
      'synthetic request 2',
      'synthetic request 1',
    ]);
  });
}
