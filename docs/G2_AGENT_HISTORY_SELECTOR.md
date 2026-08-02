# G2 agent history selector design

Status: implemented.

## Goal

An ordinary G2/R1 tap opens a compact, private history selector on the glasses.
The selector gives quick access to the five latest acknowledged exchanges for
each configured agent and to the latest saved Memo. Swipes move the selection,
tap opens the selected conversation history, and a final tap dismisses the
interaction.

This flow extends, rather than replaces, the existing behavior:

- double tap outside Memo remains the fast progress request for the last
  successfully sent agent;
- double tap during an active Memo still finalizes that Memo;
- continuous LC3 capture, VAD, STT, correction, durable files, and ordinary
  WebSocket delivery remain independent of the selector.

## Product interpretation

The selector keeps one row per agent, with that agent's most recent positively
acknowledged command as its preview. Opening the row loads up to five complete
exchanges for only that agent. The target glasses layout contains:

1. `[x]`
2. up to five configured agent rows
3. `Memo`

`[x]` is always the initially selected row. This makes opening the selector
safe: a second tap closes it unless the user intentionally swipes to private
content.

The target workflow assumes five configured agents. If more than five are
configured, the selector uses the five agents with the most recent
acknowledged sends, while retaining their relative order from the saved
configuration. The phone's Messages view remains the complete history.

## Glasses layouts

### Selector

Every option occupies exactly one rendered line. Newlines and repeated
whitespace in private content are collapsed, and each line is ellipsized to the
tested G2 width. A representative seven-row page is:

```text
> [x]
  Agent One · latest sent command…
  Agent Two · No sent message
  Agent Three · latest sent command…
  Agent Four · latest sent command…
  Agent Five · latest sent command…
  Memo · latest saved memo…
```

The marker is the only selection indicator, so the layout remains grayscale
and does not rely on color. The implementation uses a 48-rune row budget. The
complete page remains bounded to 512 characters.

History rebuilds the active Hub surface as a dedicated 576x288 text page. A
second startup/create command is not sufficient after the visualizer exists;
the firmware retains the visualizer's compact 520x64 gesture slot, clipping
the lower rows and producing a misleadingly short scroll indicator. Dismissal
rebuilds the visualizer page and resumes pulse rendering.

### Recent conversations

Selecting an agent opens its five newest acknowledged exchanges, newest first:

```text
[ Agent: Agent One ]
Latest conversation
You: <most recent command>
Agent: <correlated response or No response yet>

Earlier conversation 2
You: <previous command>
Agent: <correlated response or No response yet>

[ Tap to dismiss ]
```

Commands and responses may wrap because this is a detail view, not a selector
row. Memo and conversation details use eight body lines per page with a
bounded `[ current/total · Tap to dismiss ]` footer. This fills the complete
ten-line viewport without sacrificing the title or action row. Swipe down
advances one page and swipe up returns one page; pages stop at either boundary
instead of wrapping. A final tap clears the private text and restores the audio
visualizer. Loading is bounded to five direct ledger paths and never scans the
complete message archive.

Every detail page begins with `[ Memo ]` or `[ Agent: <name> ]`. Explicit LF,
CRLF, and CR line breaks in saved Memo or response text remain hard line breaks;
blank paragraph separators remain blank display rows. Only horizontal spacing
is normalized before long lines are wrapped.

Each logical page change rebuilds the full-height text surface instead of only
updating its content. Current G2 firmware preserves the native text viewport
after the swipe that generated the app event; rebuilding resets that viewport
to the top and re-registers the invisible gesture-capture container. This keeps
Memo and agent detail paging visibly synchronized with app state.

Multi-page detail mode adds one firmware-valid 20-pixel-wide image container at
the right edge. Its final 4 pixels form one continuous solid rectangle; the
other 16 are black, so there are no segmented glyphs or visible background
track. The thumb shrinks and moves from top to bottom in proportion to the
current host page. A one-page detail does not need an indicator and therefore
does not create the otherwise over-height image. The image overlays the edge
of the full 576-pixel text surface; conservative 45-rune host wrapping keeps
the last words readable instead of narrowing and clipping the detail body to
make room for the thumb. Selector pages do not create the image container.

### Empty Memo or agent row

Memo is always present:

```text
  Memo · No saved memo
```

An agent with no positively acknowledged command is also retained:

```text
  Agent Two · No sent message
```

Tapping either empty row shows the same one-line state plus
`[ Tap to dismiss ]`; it never fabricates or sends agent work. An acknowledged
command without a correlated response remains visible with `No response yet`.

## Gesture contract

### Selector closed

| Gesture | Result |
| --- | --- |
| Tap | Open selector with `[x]` selected |
| Double tap | Request progress for the last successfully sent agent |
| Swipe up/down | Preserve the existing ordinary gesture behavior |
| Double tap during active Memo | Finalize Memo; do not open the selector |
| Tap during active Memo | Memo retains display ownership; do not open the selector |

### Selector open

| Gesture | Result |
| --- | --- |
| Swipe up | Select the previous row, wrapping before `[x]` |
| Swipe down | Select the next row, wrapping after the last row |
| Tap on `[x]` | Clear the selector and restore the audio visualizer |
| Tap on Memo | Show the most recent saved Memo, or the empty state |
| Tap on an agent with a command | Show its five newest conversations |
| Tap on an agent without a command | Show `No conversation yet`; do not send |
| Double tap | Consume without a second request so selector state stays deterministic |

### Detail page

| Gesture | Result |
| --- | --- |
| Tap during `Listening…` | Finalize the current speech for correction/send; keep detail open |
| Tap during `Sending:` | Prioritize the queued correction; keep detail open |
| Tap after `Sent:`/`Saved:` or with no active speech | Dismiss the interaction |
| Swipe up in Memo/conversation detail | Show the previous page |
| Swipe down in Memo/conversation detail | Show the next page |
| Double tap | Ignore |

The interaction stays open until the user taps. There is no automatic
two-second clear on selector or detail pages.

## State machine

```text
normal
  └─ tap ─► selector([x] selected)
               ├─ swipe ─► selector(other row selected)
               ├─ tap [x] ─► normal
               ├─ tap Memo/empty ─► detail
               └─ tap agent ─► five-exchange detail

detail
  ├─ swipe up/down ─► previous/next bounded detail page
  └─ tap ─► normal
```

Only one selector interaction may exist. Opening a new interaction is
impossible until the current one is dismissed.

## Defining "sent" and "response"

A command becomes selectable as sent only after:

- a modern `message.send` receives a positive matching `message.accepted`; or
- a legacy command is written successfully, consistent with the existing
  legacy contract.

A rejection, acknowledgement timeout, queue expiration, configuration change,
or failed legacy write does not replace the prior successful command.

A response belongs to a modern command only when:

- `message.progress` or `message.completed` carries the command's
  `request_id`; or
- `summary.result` carries a summary request ID that the selector explicitly
  associated with that command.

A readable event that names the same agent but has no matching request
correlation is saved as normal inbound history but is not silently attached to
the selected command. This prevents a response to older work from appearing as
the answer to newer work.

Legacy messages have no durable correlation contract. While the current app
process is alive, a readable event may be associated with the latest live
legacy send for the same agent. After restart, an uncorrelated legacy command
remains visible with `No response yet`; opening history does not send a new
request.

## Summary request behavior

Agent-history selection is read-only. The separate double-tap progress shortcut
can still send a modern summary request for the last acknowledged agent:

```json
{
  "type": "summary.request",
  "request_id": "<unique-summary-request-id>",
  "agent": "Agent One"
}
```

Legacy mode sends:

```json
{
  "type": "local",
  "agent": "Agent One",
  "message": "progress_summary"
}
```

The summary request remains an optional downstream operation. It does not
enter or reorder the normal command FIFO. Capture, VAD, STT, correction, raw
files, corrected files, and access to the original transcript remain
unaffected.

Each connect and send attempt is bounded. Selecting an agent never waits for a
connection, acknowledgement, or new agent response; it reads only the durable
exchange ledger and its direct message-file paths.

## Memo behavior

Memo is local and is never sent to the agent WebSocket by this selector.

- The selector row uses the newest saved Memo and a one-line preview.
- Tapping Memo opens the bounded saved note with `[ Tap to dismiss ]`.
- An active Memo owns the display and prevents the selector from opening.
- If Memo starts while the selector is open, Memo preempts and closes the
  selector before rendering its own page.
- Memory pressure may close the selector, but must not delete the saved Memo or
  agent exchange history.

## Required data model

The current `.sent.message.txt` and `.received.message.txt` files contain human
readable text but do not preserve enough structure to correlate a response
with a command. Implementation therefore adds an app-private exchange ledger:

```text
AgentExchange
  local_exchange_id
  agent
  sent_message_path
  sent_at
  delivery_request_id?
  delivery_mode
  latest_response_path?
  latest_response_at?
  latest_response_kind?
  pending_summary_request_id?
```

The ledger contains no endpoint, secret, upgrade headers, transcript text, or
response text. Text remains in the existing atomic message files. The ledger
stores only app-private correlation metadata and file references.

For durability:

- update the ledger atomically after the corresponding message file is saved;
- keep `.sent.message.txt` and `.received.message.txt` as durable content
  sources;
- treat SQLite only as a rebuildable performance index;
- never export request IDs or ledger metadata to shared storage;
- never write agent names, request IDs, or private message text to logs;
- rebuild the selector from app-private atomic records after restart;
- retain one latest-exchange preview per configured agent in the selector and
  load at most five exchanges for the selected agent's detail view.

On the first ledger-capable launch, the store performs a one-time import of the
newest existing `.sent.message.txt` file for each configured agent. Imported
commands have no historical request ID, so they remain selectable with
`No response yet` instead of claiming correlation that the older files cannot
prove. A configuration change clears live selector records and marks that
migration complete so old-server messages are not reintroduced later.

Changing WebSocket configuration clears the in-memory selector and pending
summary association. Durable records remain visible in the phone's Messages
history, but records from the prior configuration are not offered as live
selector targets for the new server.

## Display ownership and concurrency

The display owner priority is:

1. active Memo;
2. agent history selector/detail interaction;
3. normal transcript and inbound-message status queue;
4. visual audio pulse.

The normal status owner also uses the full-height text page for `Queued:`,
`Sending:`, `Sent:`, `Saved:`, and `Received:` content. It restores the compact
visualizer only when the current FIFO item clears; the two-row visualizer text
slot is reserved for short gesture labels.

While the selector owns the display:

- normal statuses continue their durable work but cannot overwrite the page;
- `Listening…`, `Sending:`, and terminal detail renders enter the coalesced
  display queue without blocking Gemma correction, WebSocket delivery, or
  acknowledged-message persistence;
- a corrected transcript bound to the selected agent bypasses the ordinary
  outbound FIFO and its busy backoff, while unselected routes retain that
  queue; the selected detail still waits for its own positive acknowledgement
  before changing from `Sending:` to `Sent:`;
- unrelated inbound events are persisted and deferred from the glasses;
- every BLE write remains high priority and individually time-bounded;
- dismiss sends the redundant private-text clear before restoring the audio
  visualizer;
- an unexpected disconnect retains selector or detail state for a bounded
  rerender after reconnect;
- configuration changes and app shutdown clear private selector state.

`GlassesStatusQueue` accepts an explicit display owner instead of treating
every pause as Memo. The selector does not reuse the queue's two-second
transient lifecycle because selection requires persistent,
gesture-controlled ownership.

## Implementation

1. `VoiceWebSocketClient` exposes typed outbound and inbound protocol results.
   The controller receives accepted delivery request IDs and inbound event
   metadata without logging private values.
2. The atomic `AgentExchangeStore` sits beside `WebSocketMessageStore`. It owns
   correlation metadata and rebuilds a bounded per-agent view.
3. The pure `G2AgentHistoryState` model owns selection wrapping, bounded
   conversation rendering, page state, and cancellation.
4. Tap and swipe events route through that state before ordinary gesture
   display. Active Memo remains the first gate. While the selector is closed,
   a visible `Queued:` transcript consumes single tap before selector open:
   leading `Hey` changes the item to `Sending:` and prioritizes correction;
   anything else resolves to `Saved:`.
   Double tap retains its existing shortcut only while the selector is closed.
   While the selector highlights an agent row or its agent detail page
   remains open, VAD speech start snapshots that configured agent for direct
   routing without a spoken wake word or name. Agent details show an active
   dot and the latest targeted transcript lifecycle in their body.
5. Persistent selector and detail pages use the full 576×288 G2 text
   container. Multi-page details overlay one variable-height right-edge bitmap
   with a visible 4-pixel thumb inside a valid 20-pixel container. Both use
   high-priority bounded writes.
6. The latest saved Memo is read locally without routing it through WebSocket
   or the agent exchange store.
7. Selector rendering reads app-private atomic records and does not wait on a
   shared-folder scan or SQLite cache.

## Test plan

### Pure state tests

- opening always selects `[x]`;
- swipe up/down wraps across `[x]`, five agent rows, and the final Memo row;
- every selector row is one line and the page remains under 512 characters;
- empty Memo and agent rows never send;
- tapping an agent loads its newest five exchanges and enters detail;
- missing responses render `No response yet` without sending a request;
- tap in detail dismisses and clears private state;
- active Memo blocks selector open and double tap still finalizes Memo.
- a queued transcript consumes tap before selector open, with leading-`Hey`
  correction and immediate non-`Hey` save dispositions tested independently;
- a selected agent row and its detail page supply the same direct-speech
  target; Dismiss and Memo modes return no target;
- agent details render the active dot and `Listening…`/`Sending:`/terminal
  transcript states without replacing another newer segment;
- explicit agent selection makes non-`Hey` live speech correction-eligible,
  while unselected ambient speech remains wake-gated;
- `ladies changes` is corrected to context-supported `latest changes` before
  the selected-agent route receives it;
- tap finalizes listening or prioritizes sending without dismissing the active
  detail; terminal tap retains ordinary dismissal;
- changing selection after speech starts cannot change that segment's target;
- removing the snapshotted agent from configuration prevents the send;
- selected-agent delivery bypasses an existing busy outbound item, while the
  ordinary item remains queued for its configured retry;

### Protocol and persistence tests

- only positive modern acknowledgement updates the latest agent command;
- busy retry preserves the final accepted request ID;
- selected-agent busy, rejection, timeout, and connection loss return a saved
  result without entering the ordinary outbound queue;
- rejection and timeout retain the previous successful command;
- matching progress/completion attaches to the correct exchange;
- unrelated and uncorrelated events remain durable but unattached;
- recent-history loading returns only the selected agent's newest five
  exchanges;
- configuration change clears live selection and pending timers;
- restart rebuilds exchanges from atomic app-private metadata;
- legacy fallback never claims durable correlation it cannot prove.

### Display concurrency tests

- selector ownership prevents transcript and unrelated inbound overwrite;
- Memo preempts selector;
- multi-page details render a proportional right-edge indicator without
  changing selector geometry;
- duplicate notifications and state callbacks coalesce to one page render and
  one thumb upload while that signature is queued, active, or already shown;
- dismiss clears private text before restoring the pulse;
- BLE timeout cannot stall later selector writes;
- disconnect/reconnect rerenders no more than one bounded private page.

### Physical-device acceptance

Use a fresh Android build number and a synthetic local fixture on a
representative phone:

1. send one acknowledged command to each of five synthetic agents;
2. connect the physical G2/R1 pair;
3. tap and verify `[x]` is selected first;
4. swipe through every agent and the final Memo row, checking one-line truncation;
5. select an agent with five exchanges, verify newest-first order and that the
   right-edge indicator moves through every detail page, then tap to dismiss;
6. select an agent without a response and verify `No response yet` without any
   outbound request;
7. verify unrelated inbound events do not replace the open history page;
8. start Memo and confirm tap cannot open the selector while double tap still
   finalizes it;
9. disconnect/reconnect G2 during selection and verify bounded recovery;
10. confirm continuous capture has no gap and all sent/received files remain
    durable.

Raw screenshots, recordings, device logs, and protocol traces remain outside
the repository and are deleted or preserved only under the repository's
explicit privacy rules.

### Validation performed

On 2026-07-30, the checked-in Android validator ran on the representative
physical phone against an isolated loopback fixture with five synthetic agent
rows. It verified `[x]`-first selection, Memo selection and detail display,
Pike command persistence, the missing-response waiting page, one correlated
summary request, matching response replacement, and final dismissal. The
fixture did not connect to or send work to any configured agent session.

That historical run predates the five-exchange read-only detail behavior and
is not evidence for the newer paging contract.

This deterministic phone-side run covers the protocol, persistence, and
gesture state used by the G2 controller. Final optical readability and physical
tap/swipe actuation on a paired G2/R1 remain manual checks because the test
harness cannot mechanically actuate the wearable.

## Acceptance criteria

- Tap opens the selector with `[x]` selected when no transcript is `Queued:`.
- Tap on `Queued:` changes a leading-`Hey` item to `Sending:` and prioritizes
  its correction job, or immediately saves any other transcript without
  opening the selector.
- Speech beginning while an agent row or its detail page is selected
  sends its Gemma-corrected transcript to that current configured agent without
  requiring `Hey` or the agent name. Dismiss and Memo retain ordinary wake/name
  routing.
- Agent detail titles show an active dot beside the agent name; the
  body shows `Listening…`, then the transcript as `Sending:`, and finally
  acknowledged `Sent:` or fallback `Saved:`.
- `[x]`, up to five agent rows, and the final Memo row render as one line each.
- Swipes select deterministically and wrap.
- Only acknowledged commands appear as sent.
- Selecting an agent shows its five newest acknowledged exchanges, newest
  first, without issuing a network request.
- Every multi-page Memo or agent detail shows a right-edge page-position
  indicator that remains visible and tracks bounded swipe paging; one-page
  details do not allocate an image container.
- A missing response renders `No response yet`; unrelated events do not become
  correlated responses.
- Tap during active detail speech finishes/prioritizes its send and does not
  dismiss; tap after terminal state dismisses and restores the normal page.
- Memo and the prior double-tap behavior keep their documented priority.
- No selector operation blocks or weakens capture, storage, correction, message
  delivery, privacy, or BLE timeout boundaries.
