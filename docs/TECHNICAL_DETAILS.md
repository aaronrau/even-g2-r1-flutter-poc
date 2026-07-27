# Technical implementation details

This document contains the implementation specifics intentionally omitted from
the high-level README.

The code described here is the wearable hardware, local audio, and interaction
foundation for the broader Work Bench goal. Intent processing, the
authenticated computer bridge, and Claude Code/Codex delegation remain future
layers.

## Protocol basis

The project is standalone from MentraOS. Its G2/R1 protocol implementation was
audited against MentraOS `dev` commit
`dccb6c56380277f3d4ea5bc55c935de081a314c8` from 2026-07-24.

## G2 transport

- Groups left and right advertisements by manufacturer serial number.
- Connects the right control lens before the left lens to avoid observed
  Android GATT status-133 races.
- Negotiates a 247-byte Android MTU and high-performance connection priority.
- Authenticates both lenses, selects pipe roles, synchronizes local time,
  completes onboarding state, and initializes gestures.
- Implements the G2 protobuf subset, CRC-16, transport fragmentation and
  reassembly, page lifecycle, heartbeats, text, images, and raw writes.
- Sends EvenHub and device-setting heartbeats and retries dropped active
  connections.

## Hub page and audio

The page contains a 128x24 4-bit grayscale waveform image at the upper-left and
a gesture text container below it. Audio is kept enabled independently from
tap and double-tap input. A displayed ring event clears after three seconds;
each new event cancels and restarts that expiration timer.

The microphone notification format observed in MentraOS and on hardware is:

- 16,000 Hz;
- mono;
- 10 ms per LC3 frame;
- 40 compressed bytes per frame; and
- normally five frames / 200 compressed bytes per BLE notification.

The app journals compressed LC3, decodes it to 16 kHz PCM with Google liblc3,
segments speech with Silero VAD, and transcribes saved segments locally with a
selected Sherpa-ONNX backend: Tiny Whisper, Parakeet 110M CTC, or Parakeet 0.6B
transducer. No audio or transcript is uploaded. The display still uses the LC3
spectral global-gain index so rendering never waits for the decoder or models.

The on-glasses image is a codec-level loudness proxy rather than a
sample-accurate waveform. The phone UI meter uses decoded PCM. See
[Local audio pipeline and recovery](LOCAL_AUDIO_PIPELINE.md) for persistence,
worker boundaries, file layout, and restart behavior.

The image path refreshes at a BLE-safe maximum of roughly three updates per
second. Near-identical quiet frames are coalesced instead of retransmitted.
Each visual update still sends a complete uncompressed BMP through the G2
image-container protocol, so the smaller bitmap reduces a normal waveform
transfer from about 18 BLE packets to fewer than 10.

Audio notifications, control notifications, and display writes remain separate
logical paths. The G2 control characteristic must serialize complete messages,
so fragment writes cannot safely run on concurrent threads. The write
scheduler instead prioritizes gesture text and control traffic over queued
waveform and heartbeat work. It also briefly defers waveform refresh after
input, allowing tap/swipe feedback to complete first without interrupting LC3
reception.

## R1 routing

The app exposes one supported route: **Tri-Sync**. During pairing, the phone
briefly authenticates to the R1 management GATT service and asks it to link to
the G2 right lens. It then releases the temporary phone connection. Hub
receives the gestures firmware forwards: tap, double-tap, swipe up, and swipe
down. Hold is consumed by the global Menu and can only be inferred from
surrounding activity/lifecycle events.

Direct phone input is not an app mode. Testing showed that enabling TouchPad
reporting on the management GATT service did not emit an exclusive gesture
stream and could conflict with the ring's controller relationship to G2. The
low-level R1 protocol code remains as research and pairing infrastructure.
During that temporary management session, Work Bench reads the proprietary
`device_status` response for the R1 battery percentage; the optional standard
BLE Battery Service remains a fallback for firmware that exposes it.

Terminal protocol support remains in source for research. Terminal produces
real hold start/stop events and microphone data, but it replaces the Hub
foreground surface. The visualizer build therefore stays in Daily/Hub mode.

For physical traces and the complete feasibility analysis, see
[G2/R1 long press while an EvenHub page is active](G2_R1_HUB_LONG_PRESS.md).

## Background behavior

The visible app enables screen-sleep prevention for the app session and
reasserts it whenever the activity resumes.

Android uses a visible connected-device foreground service and
non-reference-counted partial CPU wake lock while a wearable session is
connecting, connected, or reconnecting. Service transitions are serialized,
the service uses `START_STICKY`, and switching apps does not dispose BLE
subscriptions or stop LC3 reception. The user, Android force-stop, or an OEM
battery manager can still stop it.

Android adapter shutdown can produce late RxAndroidBle errors after the Dart
subscription already received its disconnect. A process-level RxJava handler
consumes only those known transport-cancellation exceptions; other uncaught
errors still crash normally. G2 reconnect retries wait through the powered-off
state. An independent watchdog reissues the Hub audio-start command if control
links recover but LC3 notifications remain stale.

iOS declares `bluetooth-central`, which allows CoreBluetooth event delivery
while suspended subject to system scheduling. iOS does not allow an ordinary
third-party app to guarantee indefinite execution. The current BLE dependency
also does not implement CoreBluetooth state restoration after process
termination.

The app does not declare iOS background `audio`: microphone data arrives over
BLE rather than through an active `AVAudioSession`.

Transient lifecycle states never tear down the wearable services. On resume,
the app reasserts the screen and background-service policies and presents the
latest BLE state. While backgrounded, UI notifications are coalesced without
throttling BLE packets, audio reception, reconnect, heartbeats, or the G2
waveform. Diagnostic history and log-entry size are bounded; an operating
system memory-pressure signal trims nonessential logs and stale scan results
without disconnecting either wearable.

## Project map

- `lib/src/protocol/g2_protocol.dart` — G2 commands, protobuf, CRC, transport,
  images, and input decoding.
- `lib/src/audio/g2_voice_level_tracker.dart` — silence calibration and
  speech-level smoothing.
- `lib/src/audio/capture_journal.dart` — durable LC3 journal isolate and
  bounded replay queue.
- `lib/src/audio/vad_worker.dart` — Silero VAD, pre/post-roll, and atomic WAVs.
- `lib/src/audio/nnapi_attestation.dart` — disposable ONNX Runtime profiles
  that prove hardware-only NNAPI node assignment before a provider is labeled.
- `lib/src/audio/speech_model.dart` — verified STT definitions, Parakeet 0.6B
  default, and runtime model resolution.
- `lib/src/audio/speech_model_preferences.dart` — persisted Tools selection.
- `lib/src/audio/transcription_worker.dart` — selected STT isolate and durable
  transcription job ledger.
- `lib/src/audio/shared_audio_export_store.dart` — persisted Android
  document-tree selection, shared transcript listing, and file-backed playback
  state.
- `lib/src/audio/audio_pipeline_coordinator.dart` — startup gating, worker
  supervision, recovery buffers, and user-visible status.
- `third_party/sherpa_onnx_android_arm64_nnapi/` — pinned arm64 Sherpa-ONNX
  runtime fork, NNAPI CPU-device exclusion patch, licenses, and binary hashes.
- `tool/build_sherpa_nnapi_runtime.sh` — reproducible temporary-checkout build
  for the vendored Android runtime.
- `lib/src/ble/g2_connection.dart` — dual-lens lifecycle, audio, display,
  heartbeats, logging, and reconnect.
- `lib/src/protocol/r1_protocol.dart` — R1 authentication, commands, and
  event parsing.
- `lib/src/ble/r1_connection.dart` — R1 GATT lifecycle, input, battery, raw
  I/O, and reconnect.
- `lib/src/wearable_controller.dart` — permissions, scanning, persistence,
  logs, and application state.
- `lib/src/ui/home_page.dart` — simplified Home status UI and separate manual
  Tools screen.
- `lib/src/ui/home_history_panel.dart` — peer Events/Transcriptions views,
  complete saved transcript text, and shared WAV playback controls.
- `android/.../MainActivity.kt` — scoped Android document-tree access,
  transcript enumeration, and content-URI media playback.
- `android/.../BleConnectionService.kt` — Android foreground service and wake
  lock.
- `android/.../WorkBenchApplication.kt` — native BLE cancellation safety.
- `native/liblc3/` — vendored Apache-2.0 Google LC3 decoder sources.
- `assets/app_icon.svg` — cross-platform launcher-icon master.
- `tool/generate_app_icons.py` — Android/iOS icon raster generator.

## Validation

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

Protocol tests cover CRC, fragmentation/reassembly, authentication types,
command construction, manufacturer-data parsing, G2 pair grouping, gesture
decoding, LC3 global-gain extraction, and speech-level smoothing.

Hardware interoperability still requires physical G2 and R1 devices. Android
has been exercised on a representative physical phone, including
transcription/VAD worker restart, expected reset/reconnect, Android adapter
loss/recovery, and an acoustic Kokoro-to-G2 transcription loop and matched-WAV Tiny
Whisper/Parakeet comparisons. The current native LC3 decoder integration is
Android-only. Because connecting without durable audio would violate the
capture-safety contract, Connect remains gated on iOS until its native LC3
bridge is implemented.

To regenerate launcher icons after editing `assets/app_icon.svg`, install
Pillow and run:

```sh
python3 tool/generate_app_icons.py
```
