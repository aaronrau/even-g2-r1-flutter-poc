# Independent conversation analysis

Conversation analysis is an optional, disabled-by-default consumer of the
durable speech WAV. It identifies speakers and transcribes their turns without
participating in the primary transcript, correction, glasses-display, or
WebSocket route.

## Boundary

```text
G2 LC3 → journal → decode → VAD → atomic speech WAV
                                  ├─ existing STT → raw transcript
                                  │                → Gemma → agent WebSocket
                                  └─ non-awaited path-only handoff
                                     → conversation isolate
                                       ├─ pyannote segmentation
                                       ├─ TitaNet speaker signature
                                       └─ independent Parakeet 110M STT
                                          → conversation TXT + JSON
                                          → app-private SQLite turns
```

The live LC3 and PCM buffers have one owner. Conversation analysis receives a
file path only after VAD closes the same WAV already used by the existing STT
worker. It therefore allocates no second live audio buffer and cannot apply
backpressure to capture.

`ConversationAnalysisService` serializes jobs through a durable app-private
ledger. `ConversationAnalysisSupervisor` owns the native models in a separate
Dart isolate. An exception terminates or fails only that worker; the supervisor
restarts it with bounded backoff and resubmits its current job. Queue,
analysis, speaker-model, export, and SQLite failures log metadata-only status
and leave capture, VAD, ordinary STT, Gemma, BLE, and WebSocket behavior
unchanged.

## Enrollment and matching

Enable **Tools → Conversation analysis → Enable speaker-labeled
conversations**. When no primary profile exists, Home asks for three clear
single-speaker utterances and shows progress after each accepted sample. Each
sample is persisted before the next prompt, so enrollment resumes after an app
restart. Enrollment rejects a segment when diarization detects multiple
speakers or when a later sample does not match every earlier sample. A rejected
sample does not advance progress. Only after all three samples agree does the
profile become eligible to identify speech as `You`.

Each local diarization cluster produces a normalized TitaNet embedding:

- short-turn clustering uses a `0.01` cosine-distance cut, with profile
  matching responsible for reuniting repeated turns;
- non-primary profiles continue to use the independent `0.64` signature
  threshold;
- the primary profile uses a persisted calibrated threshold derived from the
  weakest pairwise similarity among its three enrollment samples, minus a
  `0.04` variation margin and clamped to `0.64`–`0.90`;
- a strong match at or above `0.78` updates its bounded centroid;
- a weaker match creates `Speaker 2`, `Speaker 3`, and so on;
- overlapping diarization spans are labeled `Overlapping speakers` instead of
  being assigned to `You`.

Each profile keeps its normalized centroid plus at most six recent signatures.
Matching uses the best saved signature so normal microphone and room variation
does not erase a previously good enrollment. The lower reuse threshold does
not update the saved signature bank unless the match also reaches the separate
`0.78` learning threshold, limiting drift from borderline matches. Speaker
profiles are app-private and persist across restarts. The bank keeps one
primary profile and the 16 most recently updated non-primary profiles. When a
new unknown speaker arrives at that limit, the oldest inactive non-primary
profile is evicted; startup also compacts profile banks created by older
unbounded builds. **Update my voice** requires three new mutually consistent
samples. Its previously calibrated centroid remains unchanged until all three
updates pass; the first update sample must also match the saved primary
threshold. **Reset speaker signatures** removes profiles but retains prior
conversation turns.

## Output and history

For `<segment>.wav`, successful optional analysis writes:

- `<segment>.conversation.txt` — readable blocks labeled by speaker and time;
- `<segment>.conversation.json` — atomic structured turn metadata;
- app-private retained metadata under
  `files/workbench/conversation/<segment>.conversation.json`;
- one row per turn in the app-private SQLite history index.

The SQLite row stores the conversation and turn IDs, speaker ID and label,
text, start/end milliseconds, match confidence, primary/overlap flags, and
update time. The **Conversation** tab renders primary `You` turns on the right
and other speakers on the left as aligned text with grayscale speaker markers.
The text file is also exported to the selected shared folder when one is
available.

**Reset You signature** removes only the primary voice profile, retains other
saved speakers and conversation history, and starts a fresh three-sample
calibration. The reset remains busy until the current result and profile
persistence are complete, preventing a late worker result from restoring the
removed signature. A speech segment that began before the reset is not accepted
as a replacement enrollment sample. Only one enrollment sample is analyzed at
a time, and the action is disabled while analysis is pending.

Atomic WAV, text, and JSON files remain the durable records. SQLite is the
fast UI index and may be rebuilt independently.

## Models and installation

The optional worker uses CPU providers independently for:

- Sherpa-ONNX INT8 pyannote segmentation 3.0;
- NeMo TitaNet Small speaker embeddings;
- Parakeet 110M conversation transcription.

The two diarization models are pinned under `models/diarization/` with Git LFS
and SHA-256 manifests. Copy them only into the selected installed app:

```sh
git lfs pull --include='models/diarization/**'
(cd models/diarization && sha256sum --check SHA256SUMS)
./tool/stage_android_diarization_models.sh --device <android-serial>
```

`tool/install_android_workbench.sh --device <android-serial>` performs this
step with the other pinned models.

## Validation

Automated acceptance includes:

- three-sample consistency, per-profile threshold calibration and migration,
  speaker signature normalization, centroid updates, and JSON validation;
- bounded legacy-profile compaction and reset cutover to the next newly started
  speech segment;
- atomic profile, pending-job, and conversation-record recovery;
- SQLite method-channel indexing and ordered conversation reads;
- enrollment, disabled, error, paging, 48dp target, and speaker-turn UI states;
- the complete existing Flutter test suite;
- both checked-in Kokoro skill contract test files before physical evidence.

`tool/validate_conversation_diarization.dart` drives the native worker directly
against clean 16 kHz WAVs. Pass three enrollment WAVs with `--enrollments`; its
legacy singular option reuses one deterministic fixture three times. The
alternating-turn case enrolls `af_maple`, runs
`af_sol`, `af_maple`, `bf_vale`, and `af_maple` turns twice, requires three
stable profiles, enforces a per-turn WER ceiling, and kills the worker with its
first turn in flight to verify queued-job recovery. On Linux, make the
Sherpa-ONNX Linux library directory available through `LD_LIBRARY_PATH` before
running the tool. Its optional `--signature-threshold` argument overrides the
default `0.64` independently from `--cluster-threshold`.

Physical acoustic testing continues to treat the existing Kokoro `af_maple`
baseline as the transport/VAD/STT safety contract. Alternating-speaker tests
add speaker assignment and worker-restart checks without substituting for or
discarding that baseline.
