# Voice WebSocket bridge

Work Bench can forward finalized local transcripts to an authenticated agent
server and return server messages to the G2 display. The bridge is optional and
downstream of durable capture, VAD, STT, raw transcript persistence, shared
folder export, and Gemma correction.

```text
G2 audio → durable capture → VAD → final raw transcript
                                      ├→ raw transcript file
                                      ├→ G2 "Queued: …"
                                      └→ Gemma correction
                                             ├→ corrected transcript file
                                             └→ configured agent match
                                                        ↓
                                             authenticated WebSocket
                                                        ↓
                                  ┌─ message.accepted → G2 "Sent: …"
                                  └─ no acknowledgement → G2 "Saved: …"
                                                           ↓ 2 seconds
                                                        clear display

Acknowledged send → durable `.sent.message.txt`
WebSocket inbound event → durable `.received.message.txt`
                        → FIFO → G2 "Received: …" → clear after 2 seconds
```

## Configuration

**Tools → Agent connection** accepts:

- an IPv4 address containing four numeric octets;
- a separate numeric port from 1 through 65535;
- a masked secret stored in app-private storage;
- `Authorization: Bearer` or `X-Voice-Api-Token` upgrade authentication;
- up to 32 case-insensitive, deduplicated agent names; and
- an optional legacy message shape.

The path is fixed to `/ws`. The complete validated schema is in
[`voice_websocket.example.json`](../voice_websocket.example.json). The runtime
file is `workbench/voice_websocket.json` under the platform application-support
directory. Atomic replacement prevents a partial save from becoming active,
and an invalid external edit leaves the last valid in-memory configuration
unchanged.

The secret is never shown in status text and is never written to Work Bench
logs. Plain `ws://` does not encrypt its upgrade headers or messages; use it
only over a trusted local connection. Android loopback addresses the phone. A
development server on a USB-connected computer can be exposed explicitly:

```sh
adb -s <android-serial> reverse tcp:8787 tcp:8787
```

## Connection protocol

The HTTP upgrade includes exactly one configured authentication header. Work
Bench sends no client hello and waits for a version-1 `connection.ready`
message before sending agent traffic.

The modern message envelope is:

```json
{
  "type": "message.send",
  "request_id": "<unique-request-id>",
  "agent": "Agent One",
  "message": "pull the latest changes"
}
```

`Sent:` is displayed only after a matching version-1 `message.accepted` with
`ok: true` and no negative `result.sent`. A rejection, timeout, closed socket,
missing agent match, or unavailable server resolves the queued display to
`Saved:`.

For a live Gemma-corrected command, the durable raw STT transcript must begin
with the complete word `Hey`. Gemma may then recover the canonical configured
agent from a mispronounced or poorly recognized following word. A bare agent
alias, a mid-sentence `hey`, or a larger word such as `heyday` is never
activation evidence and resolves to `Saved:` without a WebSocket send.

If the connection closes or the acknowledgement times out, Work Bench
reconnects once and resends the modern request with the exact same
`request_id`. Servers must treat repeated request IDs idempotently: return the
prior acknowledgement without delivering the agent command twice. An explicit
non-busy `message.error` or negative acknowledgement is not retried. The
legacy shape has no acknowledgement contract and therefore is not
automatically retried.

An `agent_busy` error or negative acknowledgement keeps the command in a
32-item, app-process-only FIFO. The head retries after a matching server
completion wakes the queue or after bounded 2, 4, 8, 15, then 30-second
backoff. Later commands cannot pass the busy head, preserving spoken order.
Each explicit busy rejection starts a new request ID, while a reconnect for an
unknown acknowledgement still reuses the original request ID. A command
expires after five minutes and resolves to `Saved:` so the queue cannot remain
stuck forever. Changing configuration, disconnecting, closing the client, or
restarting the app cancels the queue; queued commands are never restored or
surprisingly delivered in a later process.

Legacy mode sends only:

```json
{
  "agent": "Agent One",
  "message": "pull the latest changes"
}
```

Because that shape has no request correlation contract, Work Bench treats a
successful socket write as sent.

## Double-tap progress request

After a modern command receives a positive `message.accepted`, Work Bench
retains that command's canonical agent name in app-process memory. A G2/R1
double tap outside an active voice memo sends:

```json
{
  "type": "summary.request",
  "request_id": "<unique-request-id>",
  "agent": "Agent One"
}
```

When legacy mode is selected, the equivalent request is:

```json
{
  "type": "local",
  "agent": "Agent One",
  "message": "progress_summary"
}
```

The request is a direct, read-only control write and does not enter, reorder, or
block the normal `message.send` FIFO. A failed or rejected command never
replaces the last successful agent. Changing the connection configuration
clears the in-memory selection so a request cannot cross server
configurations. Disconnect and reconnect retain it for the same configuration;
an app restart does not restore it.

If no command has been sent, the glasses show `Update: Send a command first`.
If the server is unavailable, they show `Update: Unavailable`. Otherwise they
show the transient state `Update: Requesting`; the server's `summary.result`
supersedes it when received. Its `result.summary`, `result.detail`, or
`result.detail_lines` text follows the same atomic `.received.message.txt`,
shared-folder export, Messages-tab, and G2 `Received:` path as other readable
inbound events. Voice memo finalization retains priority over this action.

The client tracks the latest non-negative top-level `event_id`. After an
unexpected disconnect, it reconnects with bounded backoff, waits for the next
`connection.ready`, then sends:

```json
{
  "type": "connection.resume",
  "resume_after_event_id": 42
}
```

Changing the saved configuration clears the in-memory resume cursor so an
event ID from one server is never sent to another.

## Routing and G2 display

Configured names match as complete phrases, not substrings. Matching is
case-insensitive and the earliest match wins; a longer configured name wins a
tie. A leading spoken invocation such as `Agent One, pull the latest changes`
routes `pull the latest changes`. When the agent name appears later, the full
corrected transcript is preserved as the outgoing message.

The atomic raw transcript creates one G2 FIFO item as `Queued:` without
waiting for Gemma or the network. The segment ID follows that same item through
correction and routing, so the corrected result does not create a duplicate
display entry. The live turn reaches STT only after the nominal 1.75-second
total-silence VAD boundary; speech resuming before that boundary remains in the
same turn. When correction is enabled, the saved agent names are added to
the validated correction instructions as local command vocabulary; only the
corrected result is eligible for agent matching and WebSocket routing. Known
configured agent names also receive conservative acoustic alias guidance for
leading command invocations. Routing independently requires the complete word
`Hey` at the start of the durable raw transcript and the canonical agent phrase
in the corrected transcript. A bare acoustic variant, a mid-sentence `hey`, or
a larger word such as `heyday` is not activation evidence. Gemma may repair a
misheard agent name and command body only after the raw leading attention word
is present. The raw and corrected files remain separate. Explicitly disabling
correction permits the live raw transcript to route as a documented fallback.

The item resolves to `Sent:` only after a positive modern acknowledgement.
Every other outcome resolves to `Saved:`. The terminal state remains visible
for two seconds, is cleared with redundant EvenHub writes, and then yields to
the latest deferred inbound item. If an inbound event arrives before the
acknowledgement, the latest transcript's `Sent:` or `Saved:` state restores the
terminal display instead of being discarded as superseded. If an inbound event
arrives during the terminal hold, only the newest inbound item waits. The
active item plus that one deferred item are the complete in-memory display
bound. This visual scheduler is independent of the durable transcription and
correction ledgers, so display timing cannot block or discard audio, files,
correction, or WebSocket routing.

After a positive acknowledgement, Work Bench starts the G2 `Sent:` update and
the app-private message save/shared-folder export concurrently. The message is
never archived as sent before acknowledgement, while shared-storage latency no
longer delays the terminal G2 update.

The agent server's `message.progress` and `message.completed` events carry
their concise user-facing text under `payload.summary` or
`payload.completion_message`. Work Bench also accepts `summary.result` text
under `result`, generic `message`, `text`, or `content` fields, nested `data`,
and non-JSON text frames. Connection and acknowledgement frames are not echoed
to the glasses. A top-level inbound agent name is shown before the message.
Inbound `Received:` items share the display FIFO and clear after two seconds,
so they cannot overwrite an active transcript status.

Every acknowledged outgoing command and readable inbound message is written
through a `.part` file and atomic rename in app-private support storage. The
final filename ends in `.sent.message.txt` or `.received.message.txt`. When
File storage is selected, completed records are exported to that shared
folder. Existing records are synchronized at startup and when the folder
changes. The **Messages** tab retains both directions with saved transcripts
and their playable WAV files. The separate **Conversation** tab contains only
optional speaker-attributed turns. Normal tab loads use the app-private SQLite
history indexes; the explicit refresh action reconciles external shared-folder
edits. A persistence or export failure never blocks the G2 display or
WebSocket receive loop.

If G2 is temporarily disconnected, Work Bench retains the FIFO. A terminal
two-second hold starts only after that terminal state was written successfully.
If the hold elapsed while disconnected, Work Bench clears the stale state
before advancing after reconnection. Display and socket operations are
serialized independently so neither can stall the audio pipeline. Text states
use the high-priority BLE queue, audio-pulse updates remain low priority, and an
individual BLE write times out after two seconds so a stalled visual transfer
cannot block every later status indefinitely.

## Reliability and privacy boundaries

- WebSocket ready and acknowledgement waits are bounded.
- Modern `agent_busy` commands use a bounded, expiring, in-memory FIFO; its
  retry timer and pending futures are canceled on configuration changes,
  disconnect, and shutdown.
- Reconnect delay is bounded and all timers, subscriptions, and pending
  acknowledgements are canceled when configuration changes or the client
  closes.
- Socket errors never restart Bluetooth, VAD, STT, Gemma, or durable capture.
- The full raw transcript remains in its normal local file regardless of route
  outcome.
- Transcription and correction jobs restored after app or process restart may
  update their local files but can never send an old command. Only a
  transcription captured and corrected live in the current process is
  routable.
- Logs contain only generic state, authentication mode, agent count, character
  count, and sent/saved outcome. They exclude endpoint, secret, headers,
  request and server-session IDs, transcript text, and inbound content.

## Local protocol fixture

The repository includes a metadata-only local fixture for UI and device
validation. It accepts either supported upgrade header, sends
`connection.ready`, acknowledges modern messages, emits one generic inbound
event, and records only shape and character count:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --secret <local-secret> \
  --port 8787
```

Add `--busy-responses 1` to reject the first modern request with
`agent_busy`, then accept its queued retry. This provides a deterministic
device-side FIFO validation without invoking a real agent.

The checked-in Android validation target sends two synthetic commands and
requires the busy retry plus the following FIFO command to be acknowledged.
Increment the Android build suffix in `pubspec.yaml` immediately before the
`flutter run`, then use:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --secret synthetic-queue-validation-secret \
  --port 18787 \
  --busy-responses 1
adb -s <android-serial> reverse tcp:18787 tcp:18787
flutter run -d <android-serial> \
  -t tool/validate_voice_websocket_queue_on_android.dart \
  --dart-define=WORKBENCH_QUEUE_FIXTURE_PORT=18787
```

The validator exits successfully only when both sends complete in order and
the in-memory queue is empty. Remove the `adb reverse` rule after validation.

The companion physical-Android summary validator requires an acknowledged
synthetic command, resolves the ordinary double-tap action, sends the modern
`summary.request`, and requires the fixture's `summary.result` to traverse the
client's inbound path:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --secret synthetic-summary-validation-secret \
  --port 18788
adb -s <android-serial> reverse tcp:18788 tcp:18788
flutter run -d <android-serial> \
  -t tool/validate_voice_websocket_summary_on_android.dart \
  --dart-define=WORKBENCH_SUMMARY_FIXTURE_PORT=18788
```

Increment the Android build suffix before this `flutter run` and remove the
reverse rule after validation.

For an Android phone connected over USB:

```sh
adb -s <android-serial> reverse tcp:8787 tcp:8787
```

For a phone connecting directly over a trusted LAN, bind the fixture to all
IPv4 interfaces and save the computer's LAN address in Work Bench:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --host 0.0.0.0 \
  --secret <local-secret> \
  --port 8787
```

The fixture never prints the secret, agent message, request ID, or server
session ID. Use a synthetic secret and agent name for validation. The fixture
uses unencrypted `ws://`; never expose its all-interface bind beyond a trusted
local network.
