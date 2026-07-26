# Local audio pipeline and recovery

```text
G2 BLE notifications
        │
        ▼
 durable LC3 journal isolate ────────► 15-minute raw recovery files
        │ acknowledged packets only
        ▼
 native LC3 decoder
        │
        ▼
 fixed clipping-safe gain
        │ 16 kHz mono PCM
        ├──────────────► one-second UI meter summaries
        ▼
 VAD isolate ── 5 s pre-roll / 1 s endpoint ──► atomic speech WAV
        │                              │
        │                              └──────► selected shared folder
        ▼
 transcription supervisor + job ledger
        │
        ▼
 selected STT isolate ─────────────► atomic transcript + JSONL index
                                               │
                                               └──► selected shared folder
```

The capture journal, decoder, VAD, transcription, BLE callbacks, and Flutter
rendering do not share a work queue. A slow model or UI frame cannot block raw
audio persistence. Flutter repaints at up to 30 FPS while every BLE audio
packet continues through the capture path.

## Startup contract

The app renders immediately, then initializes storage, LC3, acceleration
capabilities, VAD, and transcription in order. The Connect button remains
disabled until all local audio components report ready. Model files are copied to
app-private storage with SHA-256 verification; a verified marker avoids
rehashing large files on each launch.

The Android device is probed for GPU/OpenGL and NNAPI API availability before
either model worker is created. These values are hardware and platform hints,
not provider proof. Silero VAD and the selected transcription model qualify
their providers independently and report separate provider markers.

The checked-in arm64 Flutter FFI package replaces the public
`sherpa_onnx_android_arm64` artifact. It pins Sherpa-ONNX `v1.13.4` and ONNX
Runtime `1.27.0`, compiles Sherpa for Android API 27 so the NNAPI registration
branch exists, and passes `NNAPI_FLAG_CPU_DISABLED`. That flag excludes NNAPI's
reference-CPU device; ONNX Runtime's normal CPU provider still handles
unsupported nodes and remains the whole-model fallback.

Android API 29 is the minimum for offering the NNAPI candidate because older
Android versions ignore the CPU-disabled flag. The worker creates a temporary
provider configuration in the app cache, enables ONNX Runtime profiling,
decodes silent input, destroys the candidate so the profile is finalized, and
counts provider-assigned node executions. It accepts `nnapi` only when at least
one node names `NnapiExecutionProvider`. Raw profiles are deleted immediately
and never enter the user-selected audio folder. A missing, malformed, or
CPU-only profile retries with `cpu`.

The packaged runtime has no Android GPU or Qualcomm QNN execution provider.
NNAPI may route compatible partitions to a vendor NPU, DSP, or GPU, but its API
does not let Work Bench promise which accelerator a vendor driver selects.
Direct Qualcomm NPU execution is a separate deployment target requiring a
QNN-enabled native runtime, redistributable QNN libraries, and qualified
device/model artifacts.

Static graph inspection explains why a valid runtime can still select CPU:

| Workload | Relevant graph boundary |
| --- | --- |
| Silero VAD | The wrapper contains nested `If` and `LSTM` nodes, neither of which establishes an NNAPI partition by itself |
| Parakeet 110M INT8 | Uses `DynamicQuantizeLinear`, `ConvInteger`, `MatMulInteger`, and `LayerNormalization` forms outside the documented NNAPI operator path |
| Parakeet 0.6B INT8 | Uses the same dynamic integer forms, plus a Microsoft-domain dynamically quantized LSTM decoder |
| Tiny Whisper | Contains supported matrix/convolution work but also `Erf`, dynamic shape, range, scatter, expand, and selection operations that can fragment partitions |

The table is a compatibility warning, not provider evidence. Qualification is
recorded independently for Silero VAD, Parakeet 0.6B, Parakeet 110M, and Tiny
Whisper on each runtime, OS, and device family.

Rebuild the pinned package with:

```sh
ANDROID_SDK=<android-sdk-directory> \
ANDROID_NDK=<android-ndk-directory> \
  ./tool/build_sherpa_nnapi_runtime.sh
```

The package README, patch, licenses, and SHA-256 runtime manifest are under
`third_party/sherpa_onnx_android_arm64_nnapi/`.

## Audio safety

- G2 supplies five 40-byte, 10 ms LC3 frames in each normal 200-byte
  notification. Work Bench pins capture to the first active lens so duplicate
  left/right notifications are not decoded twice.
- A packet reaches decoding only after its sequence, timestamp, length,
  checksum, and bytes have been flushed to the append-only journal.
- Decoded PCM receives a fixed 16× clipping-safe gain before metering, VAD,
  speech-WAV persistence, and transcription. G2 microphone output otherwise
  remains well below the operating range of the local speech models. The raw
  LC3 journal is unchanged and remains available for recovery.
- The journal flushes at most every 250 ms or five packets and rotates about
  every 15 minutes.
- Pending packets stay in memory while the journal isolate restarts. If the
  bounded queue reaches 600 packets, Work Bench disconnects the wearables
  instead of silently dropping unjournaled source audio.
- VAD saves speech only. It keeps five seconds before speech and captures one
  second of PCM after the last positive VAD detection. The `speech_ended`
  marker reports that duration as `audio_ms`, independent of UI scheduling. It
  writes a partial WAV first and atomically renames completed files. After
  finalization, the completed turn is removed from pre-roll before buffering
  the next turn.
- A wearable disconnect flushes an active VAD segment before changing link
  state. Raw journals, WAV files, and completed transcripts are never deleted
  by a model restart.

Files use the application-support directory:

```text
workbench/audio/
├── journal/lc3-<UTC timestamp>.wblc3
└── speech/
    ├── <segment>.wav
    ├── <segment>.txt
    ├── pending-transcriptions.json
    └── transcripts.jsonl
```

App-private storage remains the reliable source of truth. On Android, the
**Tools → Transcription → File storage** setting opens the system folder picker
and retains only the narrow document-tree grant selected by the user. Completed
speech WAV and text files are copied into that folder so they are visible in
Files and to other apps with access to the same location. Choosing a folder
also copies existing completed speech files.

Shared export is downstream from durable capture: a revoked grant, unavailable
document provider, or copy failure never blocks journaling, VAD, or local
transcription. The UI reports the export failure and asks the user to choose
the folder again. Raw LC3 journals, partial files, the transcription ledger,
the JSONL index, and model files stay app-private.

## Failure isolation and recovery

| Failure | Recovery | BLE/audio impact |
| --- | --- | --- |
| Journal isolate exits | Replays all unacknowledged packets after restart | No loss while the bounded queue has capacity |
| VAD isolate exits | Restarts and replays up to 30 seconds of PCM | Journal and BLE continue |
| Transcription isolate exits | Restarts the model and resubmits ledger jobs | Journal, VAD, and BLE continue |
| G2 audio notifications stall | Reissues the Hub audio-start command | Does not restart BLE or models |
| Expected Disconnect | Flushes speech and keeps models loaded | User can immediately reconnect |
| Unexpected G2 link loss | Flushes speech, retries both lenses, restores Hub audio | Process and local model workers stay alive |
| Android adapter turns off | Ignores only late native BLE cancellation errors, waits, reconnects after adapter recovery | Process remains alive |
| Capture queue overflows | Logs a fatal safety marker and disconnects | Prevents silent source loss |
| Shared folder is unavailable | Keeps app-private files and prompts for a new folder grant | Journal, VAD, transcription, and BLE continue |

Tools exposes diagnostic VAD and transcription restarts. These controls kill
only the selected worker, making the recovery paths testable without cycling
Bluetooth.

## Model setup

Large model artifacts are intentionally not committed. Install the exact
hash-verified Sherpa-ONNX models before building:

```sh
./tool/fetch_speech_models.sh
```

The script downloads the official Silero VAD and `tiny.en` Whisper release,
verifies every runtime file, and installs it under `assets/models/`. Tiny
Whisper remains the portable bundled fallback.

Parakeet 0.6B is the default selection. Parakeet 110M and Tiny Whisper can be
selected from **Tools → Transcription**, and the selection persists across app
restarts. The Parakeet files stay out of the APK and must be staged into
app-private storage:

```sh
./tool/stage_android_stt_model.sh parakeet-110m
./tool/stage_android_stt_model.sh parakeet-0.6b
flutter run
```

Changing the setting verifies the requested files before stopping the current
worker, then reloads only transcription. Raw capture, BLE, ring input, and VAD
continue, and any interrupted WAV remains in the durable ledger for the new
worker. A load failure restores the prior model and does not change the saved
preference.

Parakeet 110M is the lower-memory option; the 0.6B model requires substantially
more memory. The 0.6B model remains the default by product choice. All STT
variants remain behind the same
transcription-worker boundary and cannot own the journal, BLE callbacks, or VAD
recovery buffer.

See [Transcription turn test plan](TRANSCRIPTION_TURN_TEST_PLAN.md) for the
computer-speaker Kokoro cases and turn-level acceptance criteria.
