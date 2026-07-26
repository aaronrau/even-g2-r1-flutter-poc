# Work Bench

Work Bench is a local-first wearable work agent built around the Even
Realities G2 glasses and R1 ring.

## Project goal

The goal is to turn continuous G2 audio and intentional R1 gestures into a
hands-free interface for managing technical work. An on-device, local-first
mobile agent interprets requests, maintains task context, asks for confirmation
when needed, and delegates well-scoped work to Claude Code or Codex terminal
sessions running on the user's computer. Progress, questions, and results can
then return to the glasses, with the ring providing discreet approval and
navigation.

```text
G2 audio + R1 gestures
          ↓
Work Bench mobile agent
          ↓
Authenticated local computer bridge
          ↓
Claude Code / Codex terminal workers
          ↓
Status, questions, and approvals on G2 + R1
```

This repository combines the hardware foundation already needed for that
vision: low-level dual-lens G2 BLE, R1 connectivity and gesture research,
continuous LC3 audio, durable local capture, VAD, on-device transcription,
on-glasses feedback, background operation, reconnect and Hub-page recovery,
raw diagnostics, and the documented firmware limitations. Intent processing,
the computer bridge, and terminal delegation are the next product layers.

Here, **local-first** means the wearable connections, session control, desktop
bridge, and owned context stay on the user's devices. Claude Code or Codex may
still use whichever hosted model services the user configures.

## Hub soft-kiosk goal

This build keeps a custom EvenHub page active with continuous microphone
streaming. The page starts without text, shows a voice-responsive waveform,
and displays R1 gestures beneath it.

It is a best-effort **soft kiosk**, not a firmware-level locked mode. The app
can restore its page and audio stream after recoverable interruptions, but the
G2 operating system still owns the global Menu and other system surfaces.

## Limitations

| Requirement | Current result |
| --- | --- |
| Stay in Daily/Hub mode | Yes; `MODE_DAILY` is reasserted after connection |
| Start and maintain microphone streaming | Yes; starts automatically and restarts after recovery |
| Keep tap and double-tap from stopping audio | Yes; both are display-only events |
| Show tap, double-tap, and swipe | Yes |
| Show long press | Inferred from R1 activity and Hub lifecycle evidence |
| Receive real long-press down/up in Hub | No; available only in Terminal mode |
| Disable the native global Menu | No; firmware reserves hold for the Menu |
| Guarantee the Hub page never exits | No; native system UI has priority |
| Control R1 directly from the phone | Not exposed; tested management GATT did not emit gestures |
| Decode and transcribe G2 audio on iOS | Not yet; the native LC3 bridge is currently Android-only |
| Run indefinitely in the background | Android is best-effort; iOS cannot guarantee this |

The fundamental limitation is that Daily/Hub mode publishes tap, double-tap,
and swipe, while the G2 firmware consumes hold as the global Menu command.
Terminal mode exposes real hold start/stop events, but Terminal and an EvenHub
page cannot own the foreground simultaneously.

See the [hardware-verified Hub/Terminal long-press analysis](docs/G2_R1_HUB_LONG_PRESS.md)
for protocol traces, approaches tested, and what Even Realities would need to
expose for a true locked Hub mode.

## From hardware POC to work agent

| Layer | Status |
| --- | --- |
| G2/R1 discovery, connection, protocol, and diagnostics | Implemented |
| Continuous LC3 stream, waveform, gestures, and Hub recovery | Implemented |
| Android foreground operation and iOS background-central support | Implemented within platform limits |
| Durable LC3 capture, VAD, and selectable local Whisper/Parakeet STT | Implemented on Android |
| On-device intent, task context, and approval policy | Planned |
| Authenticated bridge to the user's computer | Planned |
| Claude Code and Codex terminal adapters | Planned |
| Glasses status, questions, approvals, cancellation, and results | Planned |

## Current hardware experience

- Connects both G2 lenses and an R1 ring.
- Starts raw 16 kHz mono LC3 streaming automatically.
- Journals compressed audio before decoding, saves VAD speech with a
  five-second pre-roll and one-second endpoint delay, and transcribes locally
  with a Tools-selectable local model. Parakeet 0.6B is the current default;
  Parakeet 110M and Tiny Whisper remain available.
- Draws a thin waveform in the upper-left using LC3 global gain and an adaptive
  silence floor.
- Displays `Tap`, `Double tap`, `Swipe up`, `Swipe down`, and
  `Long press (inferred)`.
- Shows one live audio summary plus concise connection, gesture, and lifecycle
  events without flooding the Home screen with raw packets.
- Keeps manual display commands and raw G2 diagnostics behind the upper-right
  **Tools** icon.
- Uses an Android foreground service and declares iOS
  `bluetooth-central` background support.
- Prevents screen sleep while the app is visible and preserves active BLE,
  reconnect, and LC3 work during temporary app switching.

## Run the current hardware POC

Use a physical phone with Bluetooth enabled:

```sh
./tool/fetch_speech_models.sh
flutter build apk --debug
flutter install --debug
./tool/stage_android_stt_model.sh parakeet-0.6b
flutter run
```

The install step creates the app-private model directory; staging then places
the hash-verified default model there without adding its large files to Git or
the APK. Stage `parakeet-110m` the same way if it should appear as a usable
lower-memory choice in Tools. Tiny Whisper is bundled by
`fetch_speech_models.sh`.

### Copy a Parakeet model to Android

Install Work Bench on the phone before copying a Parakeet model. Android must
show the phone as `device`, not `unauthorized`:

```sh
adb devices
```

With one authorized Android device connected, copy the default larger model:

```sh
./tool/stage_android_stt_model.sh parakeet-0.6b
```

When multiple Android devices are connected, select the destination explicitly:

```sh
./tool/stage_android_stt_model.sh --device <android-serial> parakeet-0.6b
```

Use `parakeet-110m` instead of `parakeet-0.6b` to copy the lower-memory model:

```sh
./tool/stage_android_stt_model.sh --device <android-serial> parakeet-110m
```

The script downloads the official Sherpa-ONNX archive into the host cache,
checks every required file against the hashes pinned in the repository, and
copies only the selected model into the installed app's private
`files/workbench/models/<model-id>` directory. The model is not added to Git or
the APK.

Cold-start the app after staging so it can verify the copied files and create
its `.verified` markers:

```sh
adb -s <android-serial> shell am force-stop \
  dev.opensourceglasses.even_g2_r1_poc
adb -s <android-serial> shell monkey \
  -p dev.opensourceglasses.even_g2_r1_poc \
  -c android.intent.category.LAUNCHER 1
```

The Home status should then read
`Local audio ready · Parakeet 0.6B · cpu`. The selected model can also be
confirmed under **Tools → Transcription**.

If the app reports that Parakeet is not installed:

1. Confirm that Work Bench is already installed on the selected phone.
2. Confirm that `adb devices` reports the phone as `device`.
3. Rerun the staging command with the correct model and, when necessary,
   `--device <android-serial>`.
4. Cold-start the app. Reinstalling with replace/update semantics preserves the
   staged files, but uninstalling the app or clearing its storage removes them.

Then:

1. Grant Nearby Devices and notification permissions.
2. Tap **Connect devices**. Work Bench scans for the G2 pair and R1, connects
   them, and releases the temporary R1 setup link after Tri-Sync handoff.
3. Speak to move the waveform and use the ring to display gestures.
4. Tap **Disconnect** to reset the complete wearable connection.

## More detail

- [Technical implementation details](docs/TECHNICAL_DETAILS.md) — G2/R1 BLE,
  LC3 analysis, background behavior, project map, and validation.
- [Local audio pipeline and recovery](docs/LOCAL_AUDIO_PIPELINE.md) — durable
  capture, VAD, transcription isolation, storage, acceleration, and failures.
- [Transcription and model test plan](docs/TRANSCRIPTION_TURN_TEST_PLAN.md) —
  physical Kokoro tests and matched-input STT comparison rules.
- [Hub/Terminal long-press analysis](docs/G2_R1_HUB_LONG_PRESS.md) — physical
  traces, firmware boundary, alternatives, and ruled-out approaches.
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md) — MentraOS audit and
  delivery architecture.

Protocol details were ported from the MIT-licensed
[MentraOS](https://github.com/Mentra-Community/MentraOS) implementation. This
project is distributed under the [MIT license](LICENSE); third-party notices
are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
