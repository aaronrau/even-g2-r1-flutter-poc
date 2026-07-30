import 'dart:async';

import 'package:even_g2_r1_poc/src/wearable_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
