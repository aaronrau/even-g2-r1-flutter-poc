import 'dart:async';

import 'package:even_g2_r1_poc/src/wearable_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'coalesces duplicate display work while the first render is active',
    () async {
      final queue = CoalescedDisplayQueue();
      final started = Completer<void>();
      final release = Completer<void>();
      var renders = 0;

      Future<void> render() async {
        renders++;
        if (!started.isCompleted) {
          started.complete();
        }
        await release.future;
      }

      final first = queue.schedule(key: 'same-page', render: render);
      await started.future;
      final duplicates = List<Future<void>>.generate(
        20,
        (_) => queue.schedule(key: 'same-page', render: render),
      );
      release.complete();
      await Future.wait(<Future<void>>[first, ...duplicates]);

      expect(renders, 1);
    },
  );

  test('renders a changed display once after the active render', () async {
    final queue = CoalescedDisplayQueue();
    final started = Completer<void>();
    final release = Completer<void>();
    final rendered = <String>[];

    final first = queue.schedule(
      key: 'selector',
      render: () async {
        rendered.add('selector');
        started.complete();
        await release.future;
      },
    );
    await started.future;
    final detail = queue.schedule(
      key: 'detail-1',
      render: () async => rendered.add('detail-1'),
    );
    final duplicate = queue.schedule(
      key: 'detail-1',
      render: () async => rendered.add('duplicate'),
    );
    release.complete();
    await Future.wait(<Future<void>>[first, detail, duplicate]);

    expect(rendered, <String>['selector', 'detail-1']);
  });

  test('retries a display key after a failed render', () async {
    final queue = CoalescedDisplayQueue();
    var attempts = 0;
    var failures = 0;

    await queue.schedule(
      key: 'detail',
      render: () async {
        attempts++;
        throw StateError('synthetic display failure');
      },
      onError: (_) => failures++,
    );
    await queue.schedule(key: 'detail', render: () async => attempts++);

    expect(attempts, 2);
    expect(failures, 1);
  });

  test('double tap requests an agent update outside a voice memo', () {
    expect(
      resolveWearableGestureAction(gestureType: 3, memoActive: false),
      WearableGestureAction.requestAgentSummary,
    );
  });

  test('double tap keeps voice memo finalization priority', () {
    expect(
      resolveWearableGestureAction(gestureType: 3, memoActive: true),
      WearableGestureAction.finishMemo,
    );
  });

  test('other gestures remain available to the normal gesture flow', () {
    for (final gestureType in <int>[0, 1, 2, 4]) {
      expect(
        resolveWearableGestureAction(
          gestureType: gestureType,
          memoActive: false,
        ),
        WearableGestureAction.ignore,
      );
    }
  });

  test('history swipes follow the G2 viewport direction', () {
    expect(
      resolveAgentHistorySelectionMove(1),
      AgentHistorySelectionMove.previous,
    );
    expect(resolveAgentHistorySelectionMove(2), AgentHistorySelectionMove.next);
    expect(resolveAgentHistorySelectionMove(3), AgentHistorySelectionMove.none);
  });

  test(
    'updates Sent display while acknowledged message persistence runs',
    () async {
      final persistenceStarted = Completer<void>();
      final releasePersistence = Completer<void>();
      var displayUpdated = false;

      final completed = completeAgentRouteConsumers(
        updateDisplay: () async {
          displayUpdated = true;
        },
        persistAcknowledgedMessage: () async {
          persistenceStarted.complete();
          await releasePersistence.future;
        },
      );

      await persistenceStarted.future;
      expect(displayUpdated, isTrue);

      var routeCompleted = false;
      unawaited(completed.then((_) => routeCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(routeCompleted, isFalse);

      releasePersistence.complete();
      await completed;
      expect(routeCompleted, isTrue);
    },
  );

  test(
    'does not persist a message when the send was not acknowledged',
    () async {
      var displayUpdated = false;

      await completeAgentRouteConsumers(
        updateDisplay: () async {
          displayUpdated = true;
        },
      );

      expect(displayUpdated, isTrue);
    },
  );
}
