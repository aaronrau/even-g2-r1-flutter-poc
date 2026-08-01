# G2 agent history selector design

Status: implemented.

## Goal

An ordinary G2/R1 tap opens a compact, private history selector on the glasses.
The selector gives quick access to the latest successfully sent command for
each configured agent and to the latest saved Memo. Swipes move the selection,
tap opens the selected result, and a final tap dismisses the interaction.

This flow extends, rather than replaces, the existing behavior:

- double tap outside Memo remains the fast progress request for the last
  successfully sent agent;
- double tap during an active Memo still finalizes that Memo;
- continuous LC3 capture, VAD, STT, correction, durable files, and ordinary
  WebSocket delivery remain independent of the selector.

## Product interpretation

The requested "most recent message sent to all the agents" is interpreted as
one selector row per agent, where each row contains that agent's most recent
positively acknowledged command. The target glasses layout contains:

1. `[x]`
2. `Memo`
3. up to five configured agent rows

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
  Memo · latest saved memo…
  Agent One · latest sent command…
  Agent Two · No sent message
  Agent Three · latest sent command…
  Agent Four · latest sent command…
  Agent Five · latest sent command…
```

The marker is the only selection indicator, so the layout remains grayscale
and does not rely on color. The implementation uses a 48-rune row budget. The
complete page remains bounded to 512 characters.

History rebuilds the active Hub surface as a dedicated 576x288 text page. A
second startup/create command is not sufficient after the visualizer exists;
the firmware retains the visualizer's compact 520x64 gesture slot, clipping
the lower rows and producing a misleadingly short scroll indicator. Dismissal
rebuilds the visualizer page and resumes pulse rendering.

### Cached response

Selecting an agent command with a correlated saved response opens:

```text
[ Agent: Agent One ]
<bounded most recent correlated response>

[ Tap to dismiss ]
```

The response body may wrap because this is a detail view, not a selector row.
The newest correlated `message.completed`, `message.progress`, or requested
`summary.result` text is shown. Memo and response details use seven body lines
per page with a bounded `[ current/total · Tap to dismiss ]` footer. Swipe down
advances one page and swipe up returns one page; pages stop at either boundary
instead of wrapping. A final tap clears the private text and restores the audio
visualizer.

Every detail page begins with `[ Memo ]` or `[ Agent: <name> ]`. Explicit LF,
CRLF, and CR line breaks in saved Memo or response text remain hard line breaks;
blank paragraph separators remain blank display rows. Only horizontal spacing
is normalized before long lines are wrapped.

Each logical page change rebuilds the full-height text surface instead of only
updating its content. Current G2 firmware preserves the native text viewport
after the swipe that generated the app event; rebuilding resets that viewport
to the top and re-registers the invisible gesture-capture container. This keeps
Memo and agent detail paging visibly synchronized with app state.

Detail mode adds one 8-pixel-wide image container at the right edge. The image
is a single continuous solid rectangle, and the container is only as tall as
that foreground thumb, so there are no segmented glyphs and no background
track. A one-page detail uses the full height. For multiple pages, the thumb
shrinks and moves from top to bottom in proportion to the current host page.
Keeping it separate from the 544-pixel-wide body preserves bounded host
pagination and does not depend on overflowing the firmware's native text
viewport. Selector and waiting pages do not create the image container.

### Waiting for a response

If the selected command has no correlated response, tap sends a read-only
summary request for that command's agent and opens:

```text
Agent One
Waiting for response…

[ Tap to cancel ]
```

The matching `summary.result` replaces this page with the cached-response
layout. An unrelated inbound event is still saved but cannot replace the
waiting page.

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
`[ Tap to dismiss ]`; it never fabricates or sends agent work.

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
| Tap on an agent with a command | Show a correlated response or request one |
| Tap on an agent without a command | Show `No sent message`; do not send |
| Double tap | Consume without a second request so selector state stays deterministic |

### Detail or waiting page

| Gesture | Result |
| --- | --- |
| Tap | Dismiss the entire interaction; if waiting, cancel the local wait |
| Swipe up in Memo/response detail | Show the previous page |
| Swipe down in Memo/response detail | Show the next page |
| Swipe up/down while waiting | Ignore |
| Double tap | Ignore |

When a response arrives, the interaction stays open until the user taps. There
is no automatic two-second clear on selector, waiting, or detail pages.

## State machine

```text
normal
  └─ tap ─► selector([x] selected)
               ├─ swipe ─► selector(other row selected)
               ├─ tap [x] ─► normal
               ├─ tap Memo/empty ─► detail
               ├─ tap agent + cached response ─► detail
               └─ tap agent + no response ─► waiting
                                                  ├─ matching result ─► detail
                                                  └─ tap/cancel ─► normal

detail
  ├─ swipe up/down ─► previous/next bounded detail page
  └─ tap ─► normal
```

Only one selector interaction and one pending summary selection may exist.
Opening a new interaction is impossible until the current one is dismissed.

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
is treated as having no response, so selecting it requests
`local`/`progress_summary`.

## Summary request behavior

For a modern selected command without a response, send:

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

The summary request remains a read-only, downstream operation. It does not
enter or reorder the normal command FIFO. Capture, VAD, STT, correction, raw
files, corrected files, and access to the original transcript remain
unaffected.

Each connect and send attempt is bounded. The waiting page may remain visible,
but there is no unbounded network completer:

- wait up to 15 seconds for the correlated result;
- on timeout, keep the page open as `Still waiting · Tap to cancel`;
- accept a late matching result while the interaction remains open;
- do not automatically resend indefinitely;
- an unexpected disconnect changes waiting to
  `Connection lost · Tap to dismiss`;
- configuration change, disconnect, app shutdown, Memo start, or user
  cancellation clears the pending association and its timer.

The user can reopen the selector and tap the command again to issue a fresh
request.

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
- retain at most the latest exchange per configured agent in the in-memory
  selector view model.

On the first ledger-capable launch, the store performs a one-time import of the
newest existing `.sent.message.txt` file for each configured agent. Imported
commands have no historical request ID, so they remain selectable but request
a fresh summary instead of claiming correlation that the older files cannot
prove. A configuration change clears live selector records and marks that
migration complete so old-server messages are not reintroduced later.

Changing WebSocket configuration clears the in-memory selector and pending
summary association. Durable records remain visible in the phone's Messages
history, but records from the prior configuration are not offered as live
selector targets for the new server.

## Display ownership and concurrency

The display owner priority is:

1. active Memo;
2. agent history selector/detail/waiting interaction;
3. normal transcript and inbound-message status queue;
4. visual audio pulse.

While the selector owns the display:

- normal statuses continue their durable work but cannot overwrite the page;
- a matching selected response updates the waiting page;
- unrelated inbound events are persisted and deferred from the glasses;
- every BLE write remains high priority and individually time-bounded;
- dismiss sends the redundant private-text clear before restoring the audio
  visualizer;
- an unexpected disconnect retains selector or detail state for a bounded
  rerender after reconnect, while waiting transitions to the explicit
  connection-lost state;
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
3. The pure `G2AgentHistoryState` model has explicit `closed`, `selector`,
   `waiting`, and `detail` states. It owns selection wrapping, line rendering,
   timeout state, and cancellation.
4. Tap and swipe events route through that state before ordinary gesture
   display. Active Memo remains the first gate; double tap retains its existing
   shortcut only while the selector is closed.
5. Persistent selector pages use the full 576×288 G2 text container. Detail
   pages use a 544×288 body and one variable-height, 8-pixel-wide right-edge
   bitmap thumb. Both use high-priority bounded writes.
6. The latest saved Memo is read locally without routing it through WebSocket
   or the agent exchange store.
7. Selector rendering reads app-private atomic records and does not wait on a
   shared-folder scan or SQLite cache.

## Test plan

### Pure state tests

- opening always selects `[x]`;
- swipe up/down wraps across `[x]`, Memo, and five agent rows;
- every selector row is one line and the page remains under 512 characters;
- empty Memo and agent rows never send;
- tap on cached response enters detail;
- tap without a response enters waiting exactly once;
- tap in waiting/detail dismisses and cancels pending state;
- active Memo blocks selector open and double tap still finalizes Memo.

### Protocol and persistence tests

- only positive modern acknowledgement updates the latest agent command;
- busy retry preserves the final accepted request ID;
- rejection and timeout retain the previous successful command;
- matching progress/completion attaches to the correct exchange;
- unrelated and uncorrelated events remain durable but unattached;
- summary request/result correlation updates only the selected exchange;
- configuration change clears live selection and pending timers;
- restart rebuilds exchanges from atomic app-private metadata;
- legacy fallback never claims durable correlation it cannot prove.

### Display concurrency tests

- selector ownership prevents transcript and unrelated inbound overwrite;
- matching response replaces waiting;
- Memo preempts selector;
- detail pages render a proportional right-edge indicator without changing
  selector or waiting geometry;
- dismiss clears private text before restoring the pulse;
- BLE timeout cannot stall later selector writes;
- disconnect/reconnect rerenders no more than one bounded private page.

### Physical-device acceptance

Use a fresh Android build number and a synthetic local fixture on a
representative phone:

1. send one acknowledged command to each of five synthetic agents;
2. connect the physical G2/R1 pair;
3. tap and verify `[x]` is selected first;
4. swipe through Memo and every agent, checking one-line truncation;
5. select an agent with a cached response, verify the right-edge indicator
   remains visible and moves through every detail page, then tap to dismiss;
6. select an agent without a response, verify one summary request, wait for its
   result, then tap to dismiss;
7. verify unrelated inbound events do not replace the waiting page;
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

This deterministic phone-side run covers the protocol, persistence, and
gesture state used by the G2 controller. Final optical readability and physical
tap/swipe actuation on a paired G2/R1 remain manual checks because the test
harness cannot mechanically actuate the wearable.

## Acceptance criteria

- Tap opens the selector with `[x]` selected.
- `[x]`, Memo, and up to five agent rows render as one line each.
- Swipes select deterministically and wrap.
- Only acknowledged commands appear as sent.
- Selecting a command shows its most recent correlated response.
- Every Memo or agent detail shows a right-edge page-position indicator that
  remains visible and tracks bounded swipe paging.
- A missing response issues exactly one read-only summary request and shows a
  persistent waiting state.
- A matching result replaces waiting; unrelated results do not.
- Tap dismisses detail or waiting and restores the normal page.
- Memo and the prior double-tap behavior keep their documented priority.
- No selector operation blocks or weakens capture, storage, correction, message
  delivery, privacy, or BLE timeout boundaries.
