import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/websocket_message_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-websocket-message-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('atomically saves a normalized received message', () async {
    final store = WebSocketMessageStore(
      supportDirectory: () async => temp,
      now: () => DateTime.utc(2026, 7, 27, 12),
    );
    await store.initialize();

    final saved = await store.save(
      direction: WebSocketMessageDirection.received,
      message: '  Agent One: Task complete.\u0000\r\nSecond line.  ',
    );

    expect(saved.fileName, startsWith('workbench-websocket-'));
    expect(saved.fileName, endsWith('.received.message.txt'));
    expect(saved.direction, WebSocketMessageDirection.received);
    final file = File(saved.path);
    expect(await file.exists(), isTrue);
    expect(
      await file.readAsString(),
      'Agent One: Task complete.\nSecond line.\n',
    );
    final partials = await temp
        .list(recursive: true)
        .where((entity) => entity.path.endsWith('.part.txt'))
        .toList();
    expect(partials, isEmpty);
  });

  test(
    'restores saved message paths and keeps rapid messages separate',
    () async {
      final store = WebSocketMessageStore(
        supportDirectory: () async => temp,
        now: () => DateTime.utc(2026, 7, 27, 12),
      );
      await store.initialize();

      final first = await store.save(
        direction: WebSocketMessageDirection.sent,
        message: 'Agent One: First request.',
      );
      final second = await store.save(
        direction: WebSocketMessageDirection.received,
        message: 'Agent One: Second response.',
      );
      final restored = WebSocketMessageStore(
        supportDirectory: () async => temp,
      );
      await restored.initialize();

      expect(first.path, isNot(second.path));
      expect(await restored.savedPaths(), <String>[first.path, second.path]);
    },
  );

  test('rejects a message with no readable content', () async {
    final store = WebSocketMessageStore(supportDirectory: () async => temp);
    await store.initialize();

    await expectLater(
      store.save(
        direction: WebSocketMessageDirection.received,
        message: '\u0000\u0001',
      ),
      throwsFormatException,
    );
  });
}
