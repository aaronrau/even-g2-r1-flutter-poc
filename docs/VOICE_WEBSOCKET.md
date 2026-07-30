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

If the connection closes or the acknowledgement times out, Work Bench
reconnects once and resends the modern request with the exact same
`request_id`. Servers must treat repeated request IDs idempotently: return the
prior acknowledgement without delivering the agent command twice. An explicit
`message.error` or negative acknowledgement is not retried. The legacy shape
has no acknowledgement contract and therefore is not automatically retried.
In particular, `agent_busy` resolves the display to `Saved:`; Work Bench does
not retain an unbounded command for surprise delivery later. The server must
publish its final completion state and release the active request before a new
command for that agent can be accepted.

Legacy mode sends only:

```json
{
  "agent": "Agent One",
  "message": "pull the latest changes"
}
```

Because that shape has no request correlation contract, Work Bench treats a
successful socket write as sent.

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
leading command invocations. Routing independently requires either the complete
selected agent phrase in the durable raw transcript or a leading `Hey` plus an
explicitly supported acoustic variant such as `flex`, as well as the canonical
agent phrase in the corrected transcript. A bare variant such as `Plus` is not
activation evidence. Gemma may repair the command body, but it cannot introduce
`Flux` or another configured agent and cause a send. The raw and corrected
files remain separate. Explicitly disabling correction permits the live raw
transcript to route as a documented fallback.

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
