# Work Bench physical transcription log contract

The validation runner consumes ordinary Android logcat plus structured Work
Bench markers. Keep marker values on one line and exclude raw audio or private
transcript context beyond the explicit test phrase.

## Required markers

The host runner brackets every acoustic stimulus with markers written through
Android's `log` command:

```text
[WorkBench][Test] state=playback_start case=<id>
[WorkBench][Test] state=playback_end case=<same-id>
```

Only audio summaries before `playback_start` may contribute to the quiet
baseline. Transcripts and VAD markers before it are stale and must not be
scored. A physical run fails if either boundary marker is absent.

The standard fixture is Kokoro `af_maple` at normal speed, deterministically
peak-normalized to 95% for physical playback, 90% computer playback volume, one
second of zero-PCM leading silence, and 500 ms of zero-PCM trailing silence.
The report must identify both the clean generated stimulus and the file
actually played with SHA-256, byte length, sample rate, channel count, and
duration, plus the applied normalization gain. Phone-speaker fallback must play
the same normalized, padded fixture. The original volume is restored in a
`finally` path.

```text
[WorkBench][Capture] state=ready journal=writable
[WorkBench][Capture] state=streaming sequence=<integer>
[WorkBench][Inference] state=attested workload=vad provider=nnapi nnapi_nodes=<positive> cpu_nodes=<integer> other_nodes=<integer> nnapi_us=<integer> cpu_us=<integer>
[WorkBench][VAD] state=ready provider=<provider> recovered=<true|false>
[WorkBench][VAD] state=speech_started segment=<id> pre_roll_ms=<integer> pre_roll_bytes=<positive>
[WorkBench][TranscriptUI] state=cleared reason=speech_started segment=<id>
[WorkBench][VAD] state=speech_ending segment=<id> delay_ms=<integer>
[WorkBench][VAD] state=buffer_cleared segment=<id> bytes=<positive> next=ready
[WorkBench][VAD] state=speech_ended segment=<id> audio_ms=<integer>
[WorkBench][Transcription] state=queued segment=<id> pending=<integer>
[WorkBench][Transcription] state=processing segment=<id>
[WorkBench][Inference] state=attested workload=stt model=<model-id> provider=nnapi nnapi_nodes=<positive> cpu_nodes=<integer> other_nodes=<integer> nnapi_us=<integer> cpu_us=<integer>
[WorkBench][Transcription] state=completed segment=<id> model=<model-id> provider=<provider> audio_ms=<integer> decode_ms=<integer>
[WorkBench][Transcript][FINAL] segment=<id> text=<recognized test phrase>
```

`speech_ending` marks the last positive VAD transition and the configured
endpoint delay. `speech_ended audio_ms` reports the PCM duration captured after
that transition. Validate `audio_ms` rather than logcat wall time because
isolate-to-UI marker delivery may be batched under load.

The current command boundary requires approximately 1.75 seconds of total
silence: Silero qualifies 500 ms before the transition, then Work Bench retains
and reports a 1,250 ms endpoint tail. A resumed positive VAD detection during
that tail cancels finalization and keeps the audio in the same turn. Therefore,
normal completed turns must report `delay_ms=1250` and approximately
`audio_ms=1250`.

The attestation marker is required only when the corresponding ready/completed
provider is `nnapi`. A CPU provider must not emit a synthetic NNAPI
attestation. The positive NNAPI node count comes from a silent warm-up profile
created in the app cache and deleted after its aggregate counts are logged.

For a complete turn, the clear, ending, buffer-clear, ended, queued, processing,
and final markers must retain the same segment ID and appear in that order.
`buffer_cleared` removes audio captured before the endpoint transition. Audio
captured after that marker remains in the bounded pre-roll so a near-boundary
next utterance does not lose its opening words. If speech resumes before the
endpoint completes, finalization is cancelled and that audio remains part of
the active turn.
`speech_started` must report the PCM already prepended from continuous capture;
the standard Work Bench window is two seconds (`pre_roll_ms=2000`) after the
ring buffer has filled.

Existing audio summaries are also accepted:

```text
[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 120/255 • gain 172
```

## Recovery markers

```text
[WorkBench][Transcription] state=restarting attempt=<integer>
[WorkBench][Transcription] state=ready recovered=true
[WorkBench][Bluetooth] state=disconnected expected=<true|false>
[WorkBench][Bluetooth] state=connected recovered=true
```

The app may also report an audio-only recovery without cycling Bluetooth:

```text
LC3 notifications stalled; re-requesting the Hub audio stream
```

## Fatal safety markers

Any of these fails a run:

```text
[WorkBench][Capture] state=failed
[WorkBench][Capture] state=dropped
[WorkBench][Bluetooth] state=disconnected expected=false
```

## Scoring

The runner normalizes transcript text using Unicode case folding, punctuation
removal, whitespace collapsing, common compound splitting, and equivalent
single-digit number forms. It then calculates word-level Levenshtein distance.
The default pass threshold is word error rate at or below `0.25`.

Audio activity must rise by the configured amount above the pre-playback
baseline. Frame rate must remain at or above the configured minimum. A worker
restart is allowed only when a subsequent ready marker is present.

Each trial uses a fresh output directory. Passing and failing artifacts are
immutable evidence and are retained together; a later pass never invalidates
or replaces an earlier failure. Report pass ratio when repeating a case.

## Matched-input model comparison

Separate physical replays are valid transport/VAD trials but invalid direct
STT comparisons. For model ranking, every candidate must decode a
byte-for-byte copy of the same saved G2 WAV. Preserve an artifact manifest
containing its SHA-256, length, sample rate, speech duration, leading/trailing
silence, expected text, playback volume, app revision, phone identity,
provider, and thread count.

For every candidate require:

```text
[WorkBench][Transcription] state=ready model=<model-id> provider=<provider>
[WorkBench][Transcription] state=completed segment=<id> model=<same-model-id> provider=<same-provider> audio_ms=<same-duration> decode_ms=<integer>
```

Score WER and final-tail coverage separately from transport and VAD. Also
record PSS/RSS/swap, thermal state, and Android low-memory/process-kill events.
An accelerator label additionally requires a CPU-disabled native profile that
shows model nodes assigned to that hardware provider. Provider configuration,
hardware capability, session creation, and warm-up alone are not sufficient.
