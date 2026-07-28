import 'package:even_g2_r1_poc/src/ble/glasses_status_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows Queued then Sent and clears after exactly two seconds', (
    tester,
  ) async {
    final display = <String>[];
    final queue = _queue(display: display);

    await queue.queueTranscript(
      segmentId: 'segment-1',
      transcript: 'Hey Flux, pull the latest changes.',
    );
    await tester.pump();
    expect(display, <String>['Queued: Hey Flux, pull the latest changes.']);

    await queue.completeTranscript(
      segmentId: 'segment-1',
      transcript: 'Flux, pull the latest changes.',
      outcome: GlassesTranscriptOutcome.sent,
    );
    await tester.pump();
    expect(display.last, 'Sent: Flux, pull the latest changes.');

    await tester.pump(const Duration(milliseconds: 1999));
    expect(display, isNot(contains('<clear>')));

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(display.last, '<clear>');
    expect(queue.pendingCount, 0);

    queue.dispose();
  });

  testWidgets('shows Saved when a transcript is not acknowledged as sent', (
    tester,
  ) async {
    final display = <String>[];
    final queue = _queue(display: display);

    await queue.queueTranscript(
      segmentId: 'segment-1',
      transcript: 'A local note.',
    );
    await queue.completeTranscript(
      segmentId: 'segment-1',
      transcript: 'A corrected local note.',
      outcome: GlassesTranscriptOutcome.saved,
    );
    await tester.pump();

    expect(display, <String>[
      'Queued: A local note.',
      'Saved: A corrected local note.',
    ]);

    queue.dispose();
  });

  testWidgets('keeps close transcript turns in FIFO order', (tester) async {
    final display = <String>[];
    final queue = _queue(display: display);

    await queue.queueTranscript(
      segmentId: 'segment-1',
      transcript: 'First raw.',
    );
    await queue.queueTranscript(
      segmentId: 'segment-2',
      transcript: 'Second raw.',
    );
    await queue.completeTranscript(
      segmentId: 'segment-2',
      transcript: 'Second corrected.',
      outcome: GlassesTranscriptOutcome.sent,
    );
    await queue.completeTranscript(
      segmentId: 'segment-1',
      transcript: 'First corrected.',
      outcome: GlassesTranscriptOutcome.saved,
    );
    await tester.pump();

    expect(display, <String>['Queued: First raw.', 'Saved: First corrected.']);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(display, <String>[
      'Queued: First raw.',
      'Saved: First corrected.',
      '<clear>',
      'Queued: Second corrected.',
      'Sent: Second corrected.',
    ]);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(display.last, '<clear>');
    expect(queue.pendingCount, 0);

    queue.dispose();
  });

  testWidgets('waits for reconnection before showing or clearing status', (
    tester,
  ) async {
    final display = <String>[];
    var connected = false;
    final queue = _queue(display: display, isConnected: () => connected);

    await queue.queueTranscript(segmentId: 'segment-1', transcript: 'Raw.');
    await queue.completeTranscript(
      segmentId: 'segment-1',
      transcript: 'Corrected.',
      outcome: GlassesTranscriptOutcome.sent,
    );
    await tester.pump();
    expect(display, isEmpty);

    connected = true;
    queue.connectionChanged();
    await tester.pump();
    expect(display, <String>['Queued: Corrected.', 'Sent: Corrected.']);

    connected = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(display, isNot(contains('<clear>')));

    connected = true;
    queue.connectionChanged();
    await tester.pump();
    expect(display.last, '<clear>');

    queue.dispose();
  });

  testWidgets('serializes received messages behind transcript status', (
    tester,
  ) async {
    final display = <String>[];
    final logs = <String>[];
    final queue = _queue(display: display, logs: logs);

    await queue.queueTranscript(segmentId: 'segment-1', transcript: 'Raw.');
    await queue.completeTranscript(
      segmentId: 'segment-1',
      transcript: 'Corrected.',
      outcome: GlassesTranscriptOutcome.sent,
    );
    await queue.queueTransient(prefix: 'Received', message: 'Agent response.');
    await tester.pump();
    expect(display, <String>['Queued: Raw.', 'Sent: Corrected.']);
    expect(
      logs,
      contains('[WorkBench][GlassesStatus] state=received_queued pending=2'),
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(display, <String>[
      'Queued: Raw.',
      'Sent: Corrected.',
      '<clear>',
      'Received: Agent response.',
    ]);
    expect(
      logs,
      contains('[WorkBench][GlassesStatus] state=received_displayed pending=1'),
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(display.last, '<clear>');

    queue.dispose();
  });

  testWidgets('dispose cancels a pending clear', (tester) async {
    final display = <String>[];
    final queue = _queue(display: display);

    await queue.queueTranscript(segmentId: 'segment-1', transcript: 'Raw.');
    await queue.completeTranscript(
      segmentId: 'segment-1',
      transcript: 'Corrected.',
      outcome: GlassesTranscriptOutcome.saved,
    );
    await tester.pump();
    queue.dispose();

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(display, <String>['Queued: Raw.', 'Saved: Corrected.']);
    expect(queue.pendingCount, 0);
  });

  testWidgets('normalizes and bounds private glasses text', (tester) async {
    final display = <String>[];
    final queue = _queue(display: display);
    final privateText = 'word\u0000  ${'x' * 600}';

    await queue.queueTranscript(
      segmentId: 'segment-1',
      transcript: privateText,
    );
    await tester.pump();

    expect(display.single, startsWith('Queued: word '));
    expect(display.single, isNot(contains('\u0000')));
    expect(
      display.single.length,
      lessThanOrEqualTo(GlassesStatusQueue.maximumMessageCharacters),
    );

    queue.dispose();
  });
}

GlassesStatusQueue _queue({
  required List<String> display,
  bool Function()? isConnected,
  List<String>? logs,
}) => GlassesStatusQueue(
  isConnected: isConnected ?? () => true,
  showText: (message) async => display.add(message),
  clearText: () async => display.add('<clear>'),
  log: (message, {bool isError = false}) => logs?.add(message),
);
