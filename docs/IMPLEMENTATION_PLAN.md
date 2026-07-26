# Work Bench implementation plan

## Goal

Build a local-first wearable work agent that uses Even Realities G2 glasses
for continuous audio and ambient feedback, the R1 ring for discreet control,
and a mobile orchestration layer to delegate work to Claude Code or Codex
terminal sessions on the user's computer.

The completed first stage is a deliberately small Flutter hardware foundation
for physical iOS and Android phones that:

- discovers and connects to both Even Realities G2 lenses;
- pairs an Even Realities R1 ring through a temporary setup connection, then
  receives its input through the G2 Tri-Sync controller path;
- initializes the reverse-engineered G2 and R1 BLE protocols;
- journals G2 LC3 before decoding, isolates VAD and transcription workers, and
  saves local speech WAV/transcript pairs;
- sends text and raw diagnostic bytes;
- displays concise connection/gesture events and a single live audio summary,
  with manual G2 commands isolated on a Tools screen;
- keeps an active Android connection in a foreground service and opts into the
  iOS CoreBluetooth background-central mode.

The current Android POC now includes the durable local speech path. It does not
yet include local intent processing, a computer bridge, terminal-agent
adapters, a production task model, or the iOS LC3 decoder bridge.

## MentraOS source audit

The implementation was traced from the MentraOS `dev` branch at commit
`dccb6c56380277f3d4ea5bc55c935de081a314c8` (2026-07-24).

Primary references:

- Android G2: `mobile/modules/bluetooth-sdk/android/src/main/java/com/mentra/bluetoothsdk/sgcs/G2.kt`
- iOS G2: `mobile/modules/bluetooth-sdk/ios/Source/sgcs/G2.swift`
- Android R1: `mobile/modules/bluetooth-sdk/android/src/main/java/com/mentra/bluetoothsdk/controllers/R1.kt`
- iOS R1: `mobile/modules/bluetooth-sdk/ios/Source/controllers/R1.swift`
- Android foreground service:
  `mobile/modules/bluetooth-sdk/android/src/main/java/com/mentra/bluetoothsdk/services/Foreground.kt`

### G2 findings

- A pair is two BLE peripherals. Advertising names contain `G2` and `_L_` or
  `_R_`. The two devices are grouped by the 14-byte serial number in
  manufacturer data (`"ER"` prefix on the cross-platform manufacturer payload).
- Advertised discovery service:
  `00002760-08c2-11e1-9073-0e8ac72e0000`.
- The current G2 firmware's GATT table places control characteristics under
  service `00002760-08c2-11e1-9073-0e8ac72e5450` and audio characteristics
  under service `00002760-08c2-11e1-9073-0e8ac72e6450`. A Flutter
  `QualifiedCharacteristic` must use these owning services rather than the
  advertised discovery UUID.
- Phone writes:
  `00002760-08c2-11e1-9073-0e8ac72e5401`.
- Protocol notifications:
  `00002760-08c2-11e1-9073-0e8ac72e5402`.
- Audio notifications:
  `00002760-08c2-11e1-9073-0e8ac72e6402`.
- Protocol payloads use small protobuf messages inside an `0xAA` transport
  frame with sync id, service id, fragmentation metadata, and CRC-16.
- Authentication differs only by phone type: iOS `3`, Android `4`.
- Audio requires a live EvenHub page, followed by the EvenHub audio-control
  command. Audio arrives as 40-byte LC3 frames: 16 kHz, mono, 10 ms. A typical
  BLE notification holds five frames (200 bytes).
- Heartbeats must continue on both lenses. MentraOS sends EvenHub heartbeats
  every 10 seconds and device-settings heartbeats every 5 seconds.
- The official app also has a private Terminal service at `0x30`.
  `TERMINAL_MODE_SYNC` selects `MODE_TERMINAL`, and
  `TERMINAL_PC_STATUS_SYNC` advertises `PC_STATUS_CONNECTED`. Firmware then
  emits `TERMINAL_VOICE_INPUT` commands for hold-to-talk. Hardware testing
  confirmed that this true hold stream is exclusive with the Daily/Hub
  foreground page.

### R1 findings

- Advertising names contain `EVEN R1` or `BCL60`.
- Service: `bae80001-4f05-4503-8e65-3af1f7329d1f`.
- Write characteristics end in `0010` and `0012`; notify characteristics end
  in `0011` and `0013`.
- Initialization writes `FC`, waits 200 ms, then writes `11` to both write
  characteristics.
- Direct R1 management notifications do not expose TouchPad gestures on the
  tested firmware. Gesture control remains a separate R1 → G2 link.
- The standard Battery Service (`180F` / `2A19`) is also supported.
- MentraOS contains a reverse-engineered ring-to-glasses `advStart` command.
  The tested ring accepts its existing controller relationship but rejects a
  repeated handoff request. This POC uses the R1 GATT connection only
  temporarily for setup, then uses G2 Tri-Sync for controller gestures.
- Daily/Hub exposes typed press, double-press, and swipe events, but not
  long-press. The POC therefore defaults to Daily mode, keeps audio
  continuous, treats typed gestures as display-only input, and labels
  lifecycle-based hold inference as an experimental fallback. See
  `G2_R1_HUB_LONG_PRESS.md`.

## Architecture

1. `WearableController` owns app state, permission handling, scanning, and
   reconnect intent.
2. `G2Connection` owns both lens connections, GATT subscriptions, protocol
   initialization, packet pacing, text display, heartbeats, raw LC3 delivery,
   and the stalled-audio watchdog.
3. `R1Connection` owns the ring connection, init sequence, notifications,
   battery polling, gestures, and raw writes.
4. `G2Protocol` is a platform-independent, unit-tested implementation of the
   protobuf and Even BLE framing used by the POC.
5. `AudioPipelineCoordinator` gates connection readiness and supervises a
   durable capture-journal isolate, native LC3 decoder, VAD isolate,
   transcription isolate, and on-disk transcription ledger.
6. `flutter_reactive_ble` provides the CoreBluetooth/Android GATT bridge. It is
   BSD-3-Clause and does not introduce a commercial-use license requirement.
7. Android runs a visible `connectedDevice` foreground service with a partial
   wake lock while a wearable session is active.
8. iOS declares `bluetooth-central`; CoreBluetooth may wake the app for BLE
   events while suspended.

## Platform boundaries

- Android can keep the process and BLE work active using a user-visible
  foreground-service notification. Users and OEM battery managers can still
  stop it.
- iOS does not allow a third-party app to promise indefinite execution.
  `bluetooth-central` allows background BLE event delivery, but the system may
  suspend or terminate the app. This POC's BLE library does not implement
  CoreBluetooth state restoration after process termination.
- Android decodes BLE LC3 locally, saves only VAD speech WAVs, and runs Tiny
  Whisper without phone microphone permission or network upload. The
  on-glasses visual remains a lightweight LC3 gain proxy.
- The capture safety gate intentionally prevents iOS connection in this
  revision because its native LC3 decoder bridge is not implemented yet.
- A hardware-free build can validate protocol bytes and app behavior, but real
  G2/R1 interoperability must be confirmed on physical devices.

## Delivery phases

1. Scaffold iOS/Android Flutter project and add BLE/permission persistence.
2. Port and unit test the G2 transport, protobuf subset, CRC, text page, audio,
   authentication, time sync, and heartbeat commands.
3. Implement G2 dual-device discovery, connection, subscription, init, text,
   raw packet, global-gain speech visualization, and audio metrics.
4. Implement R1 discovery, connection, init, gestures, battery, and raw writes.
5. Add a simplified Home connection/audio/event UI, a separate manual Tools
   screen, and persisted reconnect targets.
6. Add Android foreground service and iOS background-central configuration.
7. Run Dart formatting, analyzer, unit/widget tests, Android debug build, and
   the available iOS non-signing checks.
8. Decode LC3 into a bounded local audio pipeline with voice activity
   detection and local transcription. **Implemented and hardware-validated on
   Android; iOS decoder bridge remains.**
9. Add on-device intent parsing, task context, confirmation policy, and an
   authenticated local-network bridge to the user's computer.
10. Add queue, status, cancel, and result adapters for Claude Code and Codex
    terminal sessions.
11. Return concise progress, questions, approvals, and completion summaries to
    the G2 while using R1 gestures for navigation and confirmation.
12. Add explicit privacy controls, retention limits, audit logs, and
    least-privilege authorization for terminal delegation.
