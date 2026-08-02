import 'package:even_g2_r1_poc/src/websocket/agent_exchange_store.dart';
import 'package:even_g2_r1_poc/src/websocket/g2_agent_history_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sentAt = DateTime.utc(2026, 1, 1);

  test('opens with [x] first and renders Memo plus five agents', () {
    final state = G2AgentHistoryState();
    state.open(
      agents: const <String>[
        'Pike',
        'Agent Two',
        'Agent Three',
        'Agent Four',
        'Agent Five',
        'Agent Six',
      ],
      exchanges: <AgentExchangeView>[
        AgentExchangeView(
          id: 'pike-exchange',
          agent: 'Pike',
          message: 'validate the isolated device fixture',
          sentAt: sentAt,
          legacy: false,
        ),
      ],
      memo: 'Remember the synthetic validation result.',
    );

    expect(state.mode, G2AgentHistoryMode.selector);
    expect(state.entries, hasLength(7));
    expect(state.selected?.kind, G2AgentHistoryEntryKind.dismiss);
    expect(state.entries[1].kind, G2AgentHistoryEntryKind.memo);
    expect(state.entries.last.label, 'Agent Five');
    expect(state.render(), startsWith('> [x]\n  Memo · Remember'));
    expect(state.render().split('\n'), hasLength(7));
    expect(
      state.render().runes.length,
      lessThanOrEqualTo(G2AgentHistoryState.maximumPageCharacters),
    );
  });

  test('swipes wrap and empty Memo opens a dismissible detail', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
      );

    state.selectPrevious();
    expect(state.selected?.label, 'Pike');
    expect(state.selectedSpeechAgent, 'Pike');
    state.selectNext();
    expect(state.selected?.label, '[x]');
    expect(state.selectedSpeechAgent, isNull);
    state.selectNext();
    expect(state.selected?.label, 'Memo');
    expect(state.selectedSpeechAgent, isNull);
    state.showSelectedDetail();
    expect(state.selectedSpeechAgent, isNull);

    expect(state.mode, G2AgentHistoryMode.detail);
    expect(state.render(), startsWith('[ Memo ]\n'));
    expect(state.render(), contains('No saved memo'));
    expect(state.render(), contains('[ Tap to dismiss ]'));
  });

  test('Pike waits for only its exchange and then shows the response', () {
    final exchange = AgentExchangeView(
      id: 'pike-exchange',
      agent: 'Pike',
      message: 'report synthetic progress',
      sentAt: sentAt,
      legacy: false,
    );
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[exchange],
      )
      ..selectNext()
      ..selectNext();

    state.showWaiting(exchange);
    expect(state.selectedSpeechAgent, 'Pike');
    expect(state.render(), startsWith('[ Agent: Pike • ]\n'));
    expect(state.render(), contains('Waiting for response'));
    expect(state.acceptResponse('different-exchange', 'Wrong response'), false);
    expect(state.mode, G2AgentHistoryMode.waiting);
    expect(
      state.acceptResponse(
        'pike-exchange',
        'Pike: Synthetic device response received.',
      ),
      true,
    );
    expect(state.mode, G2AgentHistoryMode.detail);
    expect(state.render(), contains('Synthetic device response received'));
  });

  test(
    'agent detail remains an active target and renders speech lifecycle',
    () {
      final state = G2AgentHistoryState()
        ..open(
          agents: const <String>['Pike'],
          exchanges: const <AgentExchangeView>[],
        )
        ..selectNext()
        ..selectNext()
        ..showSelectedDetail();

      expect(state.selectedSpeechAgent, 'Pike');
      expect(state.render(), startsWith('[ Agent: Pike • ]\n'));

      expect(state.beginTargetedSpeech('segment-1'), isTrue);
      expect(state.render(), contains('Listening…'));

      expect(
        state.showTargetedSpeechTranscript(
          segmentId: 'segment-1',
          transcript: 'pull the latest changes',
        ),
        isTrue,
      );
      expect(state.render(), contains('Sending: pull the latest changes'));

      expect(
        state.completeTargetedSpeech(
          segmentId: 'segment-1',
          transcript: 'pull the latest changes',
          sent: true,
        ),
        isTrue,
      );
      expect(state.render(), contains('Sent: pull the latest changes'));
    },
  );

  test('a newer detail utterance cannot be overwritten by an older result', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..selectNext()
      ..showSelectedDetail()
      ..beginTargetedSpeech('segment-1')
      ..beginTargetedSpeech('segment-2');

    expect(
      state.completeTargetedSpeech(
        segmentId: 'segment-1',
        transcript: 'older command',
        sent: true,
      ),
      isFalse,
    );
    expect(state.render(), contains('Listening…'));
  });

  test('selector rows collapse private newlines and remain one line', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'pike-exchange',
            agent: 'Pike',
            message:
                'first line\nsecond line with a long synthetic payload '
                'that must be safely shortened for the glasses',
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      );

    final rows = state.render().split('\n');
    expect(rows, hasLength(3));
    expect(
      rows.last.runes.length,
      lessThanOrEqualTo(G2AgentHistoryState.maximumRowRunes),
    );
    expect(rows.last, isNot(contains('second line\n')));
  });

  test('long Memo detail pages forward and backward without wrapping', () {
    final memo = List<String>.generate(
      120,
      (index) => 'memo${index.toString().padLeft(3, '0')}',
    ).join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
        memo: memo,
      )
      ..selectNext()
      ..showSelectedDetail();

    expect(state.detailPageCount, greaterThan(1));
    expect(state.render(), contains('[ 1/${state.detailPageCount}'));
    expect(state.selectPreviousDetailPage(), isFalse);
    expect(state.selectNextDetailPage(), isTrue);
    expect(state.render(), contains('[ 2/${state.detailPageCount}'));
    expect(state.selectPreviousDetailPage(), isTrue);
    expect(state.detailPageIndex, 0);

    while (state.selectNextDetailPage()) {}
    expect(state.detailPageIndex, state.detailPageCount - 1);
    expect(state.render(), contains('memo119'));
    expect(state.selectNextDetailPage(), isFalse);
  });

  test('long cached agent response uses the same detail pager', () {
    final response = List<String>.generate(
      120,
      (index) => 'result${index.toString().padLeft(3, '0')}',
    ).join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'pike-exchange',
            agent: 'Pike',
            message: 'report synthetic progress',
            response: response,
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      )
      ..selectNext()
      ..selectNext()
      ..showSelectedDetail();

    expect(state.detailPageCount, greaterThan(1));
    expect(state.render(), startsWith('[ Agent: Pike • ]\n'));
    while (state.selectNextDetailPage()) {}
    expect(state.render(), startsWith('[ Agent: Pike • ]\n'));
    expect(state.render(), contains('result119'));
    expect(state.render().split('\n'), hasLength(10));
  });

  test(
    'agent detail shows the five newest conversations and pages both ways',
    () {
      final exchanges = <AgentExchangeView>[
        for (var index = 0; index < 6; index++)
          AgentExchangeView(
            id: 'pike-$index',
            agent: 'Pike',
            message: 'synthetic request $index with enough detail to wrap',
            response: 'synthetic response $index with enough detail to wrap',
            sentAt: sentAt.add(Duration(minutes: index)),
            legacy: false,
          ),
      ];
      final state = G2AgentHistoryState()
        ..open(agents: const <String>['Pike'], exchanges: exchanges)
        ..selectNext()
        ..selectNext()
        ..showAgentConversations(exchanges);

      expect(state.detailPageCount, greaterThan(1));
      final pages = <String>[state.render()];
      while (state.selectNextDetailPage()) {
        pages.add(state.render());
      }
      final rendered = pages.join('\n');
      expect(rendered, contains('synthetic request 5'));
      expect(rendered, contains('synthetic response 1'));
      expect(rendered, isNot(contains('synthetic request 0')));
      expect(state.selectPreviousDetailPage(), isTrue);
    },
  );

  test('detail pages preserve carriage returns and paragraph breaks', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'pike-exchange',
            agent: 'Pike',
            message: 'report synthetic progress',
            response:
                'First result\r\nSecond result\rThird result\n\nFinal paragraph.',
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      )
      ..selectNext()
      ..selectNext()
      ..showSelectedDetail();

    expect(
      state.render(),
      contains(
        '[ Agent: Pike • ]\nLatest conversation\n'
        'You: report synthetic progress\nAgent: First result\n'
        'Second result\nThird result\n\n'
        'Final paragraph.',
      ),
    );
  });
}
