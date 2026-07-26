#!/usr/bin/env python3
"""Generate Kokoro speech and validate the Work Bench G2 transcription loop."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import statistics
import struct
import subprocess
import sys
import tarfile
import time
import unicodedata
import wave
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


MODEL_NAME = "kokoro-int8-multi-lang-v1_1"
MODEL_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/"
    f"{MODEL_NAME}.tar.bz2"
)
SHERPA_VERSION = "1.13.4"
DEFAULT_TEXT = (
    "Work Bench audio safety check number seven. "
    "The glasses should transcribe every word."
)
APP_PACKAGE = "dev.opensourceglasses.even_g2_r1_poc"
ENGLISH_SPEAKERS = {
    0: "af_maple",
    1: "af_sol",
    2: "bf_vale",
}
PLAYBACK_PEAK_FRACTION = 0.95

AUDIO_RE = re.compile(
    r"\[Even G2/R1\]\[Audio\].*?"
    r"(?P<frames>\d+(?:\.\d+)?) frames/s.*?"
    r"level (?P<level>\d+)/255"
)
TRANSCRIPT_RE = re.compile(
    r"\[WorkBench\]\[Transcript\]\[FINAL\]"
    r"(?:\s+segment=\S+)?\s+text=(?P<text>.*)$"
)
UNEXPECTED_DISCONNECT_RE = re.compile(
    r"\[WorkBench\]\[Bluetooth\]\s+state=disconnected\s+expected=false"
)
CAPTURE_FAILURE_RE = re.compile(
    r"\[WorkBench\]\[Capture\]\s+state=(?:failed|dropped)"
)
TRANSCRIPTION_RESTART_RE = re.compile(
    r"\[WorkBench\]\[Transcription\]\s+state=restarting"
)
TRANSCRIPTION_RECOVERED_RE = re.compile(
    r"\[WorkBench\]\[Transcription\]\s+state=ready\b.*\brecovered=true"
)
TEST_MARKER_TAG = "WorkBenchTest"


@dataclass(frozen=True)
class Report:
    expected: str
    transcript: str | None
    word_error_rate: float | None
    audio_samples: int
    baseline_level: float | None
    peak_level: int | None
    activity_rise: float | None
    median_frames_per_second: float | None
    unexpected_disconnect: bool
    capture_failure: bool
    transcription_restarts: int
    transcription_recovered: bool
    playback_start_observed: bool | None
    playback_end_observed: bool | None
    playback_volume: float | None
    leading_silence_seconds: float | None
    trailing_silence_seconds: float | None
    checks: dict[str, bool]
    passed: bool


@dataclass(frozen=True)
class MediaVolume:
    current: int
    minimum: int
    maximum: int

    def at_fraction(self, fraction: float) -> int:
        if not 0.0 <= fraction <= 1.0:
            raise ValueError("Playback volume must be between 0.0 and 1.0")
        return round(self.minimum + (self.maximum - self.minimum) * fraction)


def cache_root() -> Path:
    configured = os.environ.get("XDG_CACHE_HOME")
    base = Path(configured) if configured else Path.home() / ".cache"
    return base / "kokoro-g2-transcription-loop"


def runtime_python() -> Path:
    return cache_root() / "venv" / "bin" / "python"


def model_dir() -> Path:
    return cache_root() / "models" / MODEL_NAME


def resolved_model_file(root: Path | None = None) -> Path:
    directory = root or model_dir()
    candidates = (
        directory / "model.int8.onnx",
        directory / "model.onnx",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise RuntimeError(f"Required command not found: {name}")
    return path


def prepare_runtime() -> None:
    root = cache_root()
    root.mkdir(parents=True, exist_ok=True)
    python = runtime_python()
    if not python.exists():
        uv = require_tool("uv")
        subprocess.run(
            [uv, "venv", str(python.parent.parent)],
            check=True,
        )

    marker = python.parent.parent / f".sherpa-onnx-{SHERPA_VERSION}"
    if not marker.exists():
        uv = require_tool("uv")
        subprocess.run(
            [
                uv,
                "pip",
                "install",
                "--python",
                str(python),
                f"sherpa-onnx=={SHERPA_VERSION}",
            ],
            check=True,
        )
        marker.write_text(f"{SHERPA_VERSION}\n", encoding="utf-8")


def _archive_path() -> Path:
    return cache_root() / "downloads" / f"{MODEL_NAME}.tar.bz2"


def _download_model() -> Path:
    archive = _archive_path()
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists() and archive.stat().st_size > 1_000_000:
        return archive

    partial = archive.with_suffix(f"{archive.suffix}.part")
    curl = require_tool("curl")
    subprocess.run(
        [
            curl,
            "--fail",
            "--location",
            "--retry",
            "5",
            "--retry-all-errors",
            "--continue-at",
            "-",
            "--output",
            str(partial),
            MODEL_URL,
        ],
        check=True,
    )
    partial.replace(archive)
    return archive


def _safe_extract(archive: Path, destination: Path) -> None:
    staging = destination.with_name(f"{destination.name}.extracting")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    with tarfile.open(archive, mode="r:bz2") as bundle:
        root = staging.resolve()
        for member in bundle.getmembers():
            target = (staging / member.name).resolve()
            if root not in target.parents and target != root:
                raise RuntimeError(f"Unsafe path in model archive: {member.name}")
            if member.issym() or member.islnk():
                raise RuntimeError(f"Model archive contains a link: {member.name}")
        bundle.extractall(staging, filter="data")

    candidates = [
        path
        for path in staging.iterdir()
        if path.is_dir()
        and (
            (path / "model.int8.onnx").exists()
            or (path / "model.onnx").exists()
        )
    ]
    source = candidates[0] if len(candidates) == 1 else staging
    required = (
        resolved_model_file(source),
        source / "voices.bin",
        source / "tokens.txt",
        source / "espeak-ng-data",
    )
    missing = [str(path.name) for path in required if not path.exists()]
    if missing:
        raise RuntimeError(f"Kokoro archive is missing: {', '.join(missing)}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    source.replace(destination)
    if staging.exists():
        shutil.rmtree(staging)


def prepare_model() -> None:
    destination = model_dir()
    if resolved_model_file(destination).exists():
        return
    archive = _download_model()
    _safe_extract(archive, destination)


def prepare() -> None:
    prepare_runtime()
    prepare_model()
    print(
        json.dumps(
            {
                "runtime": str(runtime_python()),
                "model": str(model_dir()),
                "model_name": MODEL_NAME,
            },
            indent=2,
        )
    )


def _synthesize_internal(
    text: str,
    output: Path,
    speaker_id: int,
    speed: float,
) -> None:
    import sherpa_onnx  # type: ignore[import-not-found]

    model = model_dir()
    lexicons = [
        model / "lexicon-us-en.txt",
        model / "lexicon-zh.txt",
    ]
    lexicon = ",".join(str(path) for path in lexicons if path.exists())

    config = sherpa_onnx.OfflineTtsConfig()
    config.model.kokoro.model = str(resolved_model_file(model))
    config.model.kokoro.voices = str(model / "voices.bin")
    config.model.kokoro.tokens = str(model / "tokens.txt")
    config.model.kokoro.data_dir = str(model / "espeak-ng-data")
    config.model.kokoro.lexicon = lexicon
    config.model.num_threads = max(1, min(4, os.cpu_count() or 1))
    config.model.provider = "cpu"
    config.max_num_sentences = 1
    config.validate()

    tts = sherpa_onnx.OfflineTts(config)
    samples: list[float] = []
    sample_rate: int | None = None
    sentences = _sentence_chunks(text)
    for index, sentence in enumerate(sentences):
        generated = tts.generate(sentence, sid=speaker_id, speed=speed)
        generated_samples = list(generated.samples)
        if not generated_samples:
            raise RuntimeError(
                f"Kokoro generated no audio for sentence {index + 1}"
            )
        current_rate = int(generated.sample_rate)
        if sample_rate is None:
            sample_rate = current_rate
        elif sample_rate != current_rate:
            raise RuntimeError("Kokoro changed sample rate between sentences")
        if index:
            samples.extend([0.0] * round(sample_rate * 0.25))
        samples.extend(generated_samples)
    if not samples:
        raise RuntimeError("Kokoro generated no audio samples")
    if sample_rate is None:
        raise RuntimeError("Kokoro did not return a sample rate")

    output.parent.mkdir(parents=True, exist_ok=True)
    pcm = bytearray()
    for sample in samples:
        value = max(-1.0, min(1.0, float(sample)))
        pcm.extend(struct.pack("<h", round(value * 32767)))
    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)


def _sentence_chunks(text: str) -> list[str]:
    """Split text for Kokoro, whose backend emits one sentence per request."""
    chunks = [
        chunk.strip()
        for chunk in re.split(r"(?<=[.!?])\s+", text.strip())
        if chunk.strip()
    ]
    return chunks or [text.strip()]


def synthesize(
    text: str,
    output: Path,
    speaker_id: int,
    speed: float,
) -> None:
    prepare()
    child = runtime_python()
    if Path(sys.prefix) == child.parent.parent:
        _synthesize_internal(text, output, speaker_id, speed)
        return
    subprocess.run(
        [
            str(child),
            str(Path(__file__).resolve()),
            "_synthesize",
            "--text",
            text,
            "--output",
            str(output),
            "--speaker-id",
            str(speaker_id),
            "--speed",
            str(speed),
        ],
        check=True,
    )


def normalize_words(value: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = "".join(
        character
        if character.isalnum() or character.isspace() or character == "'"
        else " "
        for character in normalized
    )
    compounds = {
        "workbench": ("work", "bench"),
    }
    numbers = {
        "zero": "0",
        "one": "1",
        "two": "2",
        "three": "3",
        "four": "4",
        "five": "5",
        "six": "6",
        "seven": "7",
        "eight": "8",
        "nine": "9",
        "ten": "10",
    }
    words: list[str] = []
    for word in normalized.split():
        for expanded in compounds.get(word, (word,)):
            words.append(numbers.get(expanded, expanded))
    return words


def parse_media_volume(output: str) -> MediaVolume | None:
    match = re.search(
        r"volume is (\d+) in range \[(\d+)\.\.(\d+)\]",
        output,
    )
    if match is None:
        return None
    return MediaVolume(
        current=int(match.group(1)),
        minimum=int(match.group(2)),
        maximum=int(match.group(3)),
    )


def get_media_volume(adb_prefix: list[str]) -> MediaVolume | None:
    result = subprocess.run(
        [
            *adb_prefix,
            "shell",
            "cmd",
            "media_session",
            "volume",
            "--stream",
            "3",
            "--get",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return parse_media_volume(result.stdout + result.stderr)


def set_media_volume(adb_prefix: list[str], volume: int) -> None:
    subprocess.run(
        [
            *adb_prefix,
            "shell",
            "cmd",
            "media_session",
            "volume",
            "--stream",
            "3",
            "--set",
            str(volume),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def get_android_property(adb_prefix: list[str], name: str) -> str:
    result = subprocess.run(
        [*adb_prefix, "shell", "getprop", name],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def android_setprop_command(name: str, value: str) -> str:
    return f"setprop {shlex.quote(name)} {shlex.quote(value)}"


def set_android_property(
    adb_prefix: list[str],
    name: str,
    value: str,
) -> None:
    command = android_setprop_command(name, value)
    subprocess.run(
        [*adb_prefix, "shell", command],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def get_computer_volume(wpctl: str) -> float:
    result = subprocess.run(
        [wpctl, "get-volume", "@DEFAULT_AUDIO_SINK@"],
        check=True,
        capture_output=True,
        text=True,
    )
    match = re.search(r"\bVolume:\s*(\d+(?:\.\d+)?)", result.stdout)
    if match is None:
        raise RuntimeError("Could not read the computer speaker volume")
    return float(match.group(1))


def set_computer_volume(wpctl: str, volume: float) -> None:
    if not 0.0 <= volume <= 1.0:
        raise ValueError("Computer speaker volume must be between 0.0 and 1.0")
    subprocess.run(
        [wpctl, "set-volume", "@DEFAULT_AUDIO_SINK@", f"{volume:.4f}"],
        check=True,
    )


def edit_distance(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_word in enumerate(left, start=1):
        current = [left_index]
        for right_index, right_word in enumerate(right, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1]
                    + (0 if left_word == right_word else 1),
                )
            )
        previous = current
    return previous[-1]


def word_error_rate(expected: str, actual: str) -> float:
    expected_words = normalize_words(expected)
    actual_words = normalize_words(actual)
    if not expected_words:
        return 0.0 if not actual_words else 1.0
    return edit_distance(expected_words, actual_words) / len(expected_words)


def _audio_values(lines: Iterable[str]) -> list[tuple[float, int]]:
    values: list[tuple[float, int]] = []
    for line in lines:
        match = AUDIO_RE.search(line)
        if match:
            values.append(
                (float(match.group("frames")), int(match.group("level")))
            )
    return values


def playback_marker(state: str, case_name: str) -> str:
    if state not in {"playback_start", "playback_end"}:
        raise ValueError(f"Unsupported playback marker state: {state}")
    safe_case = re.sub(r"[^a-zA-Z0-9_.-]+", "_", case_name).strip("_")
    if not safe_case:
        safe_case = "unnamed"
    return f"[WorkBench][Test] state={state} case={safe_case}"


def emit_android_test_marker(
    adb_prefix: list[str],
    state: str,
    case_name: str,
) -> str:
    marker = playback_marker(state, case_name)
    subprocess.run(
        [*adb_prefix, "shell", "log", "-t", TEST_MARKER_TAG, marker],
        check=True,
    )
    return marker


def split_at_marker(
    log_text: str,
    marker: str | None,
) -> tuple[str, str, bool | None]:
    if marker is None:
        return "", log_text, None
    position = log_text.find(marker)
    if position < 0:
        return log_text, "", False
    return log_text[:position], log_text[position + len(marker):], True


def build_report(
    expected: str,
    log_text: str,
    baseline_count: int,
    max_wer: float,
    min_activity_rise: float,
    min_frames_per_second: float,
    playback_start_marker: str | None = None,
    playback_end_marker: str | None = None,
    playback_volume: float | None = None,
    leading_silence_seconds: float | None = None,
    trailing_silence_seconds: float | None = None,
) -> Report:
    lines = log_text.splitlines()
    before_playback, scored_log, playback_start_observed = split_at_marker(
        log_text,
        playback_start_marker,
    )
    playback_end_observed = (
        None
        if playback_end_marker is None
        else playback_end_marker in scored_log
    )
    if playback_start_marker is None:
        audio = _audio_values(lines)
        baseline_values = [level for _, level in audio[:baseline_count]]
        scored_audio = audio[baseline_count:]
    else:
        baseline_audio = _audio_values(before_playback.splitlines())
        baseline_values = [
            level for _, level in baseline_audio[-baseline_count:]
        ]
        scored_audio = _audio_values(scored_log.splitlines())
    baseline = statistics.median(baseline_values) if baseline_values else None
    peak = max((level for _, level in scored_audio), default=None)
    rise = None if baseline is None or peak is None else peak - baseline
    median_frames = (
        statistics.median(frames for frames, _ in scored_audio)
        if scored_audio
        else None
    )

    transcripts = [
        match.group("text").strip()
        for line in scored_log.splitlines()
        if (match := TRANSCRIPT_RE.search(line))
    ]
    # VAD may intentionally split one playback into multiple durable segments.
    # Score the ordered final results as one utterance instead of discarding
    # every segment except the last.
    transcript = " ".join(transcripts) if transcripts else None
    wer = (
        word_error_rate(expected, transcript)
        if transcript is not None
        else None
    )
    restarts = sum(bool(TRANSCRIPTION_RESTART_RE.search(line)) for line in lines)
    recovered = bool(TRANSCRIPTION_RECOVERED_RE.search(log_text))
    unexpected_disconnect = bool(UNEXPECTED_DISCONNECT_RE.search(log_text))
    capture_failure = bool(CAPTURE_FAILURE_RE.search(log_text))

    checks = {
        "playback_boundary": (
            playback_start_observed is not False
            and playback_end_observed is not False
        ),
        "audio_observed": bool(scored_audio),
        "audio_activity_rise": rise is not None and rise >= min_activity_rise,
        "frame_rate": (
            median_frames is not None
            and median_frames >= min_frames_per_second
        ),
        "final_transcript": transcript is not None,
        "transcript_accuracy": wer is not None and wer <= max_wer,
        "no_unexpected_disconnect": not unexpected_disconnect,
        "capture_safe": not capture_failure,
        "transcription_recovered": restarts == 0 or recovered,
    }
    return Report(
        expected=expected,
        transcript=transcript,
        word_error_rate=wer,
        audio_samples=len(scored_audio),
        baseline_level=baseline,
        peak_level=peak,
        activity_rise=rise,
        median_frames_per_second=median_frames,
        unexpected_disconnect=unexpected_disconnect,
        capture_failure=capture_failure,
        transcription_restarts=restarts,
        transcription_recovered=recovered,
        playback_start_observed=playback_start_observed,
        playback_end_observed=playback_end_observed,
        playback_volume=playback_volume,
        leading_silence_seconds=leading_silence_seconds,
        trailing_silence_seconds=trailing_silence_seconds,
        checks=checks,
        passed=all(checks.values()),
    )


def select_adb(explicit: str | None) -> str:
    if explicit:
        return explicit
    candidates = (
        Path.home() / "Android/Sdk/platform-tools/adb",
        Path("/opt/android-sdk/platform-tools/adb"),
    )
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return require_tool("adb")


def ensure_single_device(adb: str, serial: str | None) -> str:
    result = subprocess.run(
        [adb, "devices"],
        check=True,
        capture_output=True,
        text=True,
    )
    devices = [
        line.split()[0]
        for line in result.stdout.splitlines()[1:]
        if line.strip().endswith("\tdevice")
    ]
    if serial:
        if serial not in devices:
            raise RuntimeError(f"Android device is not available: {serial}")
        return serial
    if len(devices) != 1:
        raise RuntimeError(
            f"Expected exactly one Android device, found {len(devices)}"
        )
    return devices[0]


def prepare_artifact_directory(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    if any(output_dir.iterdir()):
        raise RuntimeError(
            "Output directory is not empty; use a fresh directory so prior "
            f"test evidence is preserved: {output_dir}"
        )


def wav_manifest(path: Path) -> dict[str, object]:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    with wave.open(str(path), "rb") as wav:
        frame_count = wav.getnframes()
        sample_rate = wav.getframerate()
        return {
            "file": path.name,
            "sha256": digest.hexdigest(),
            "bytes": path.stat().st_size,
            "sample_rate_hz": sample_rate,
            "channels": wav.getnchannels(),
            "sample_width_bytes": wav.getsampwidth(),
            "frame_count": frame_count,
            "duration_seconds": frame_count / sample_rate,
        }


def peak_normalized_wav_copy(
    stimulus: Path,
    output_dir: Path,
    *,
    target_fraction: float = PLAYBACK_PEAK_FRACTION,
) -> tuple[Path, dict[str, float | int]]:
    if not 0.0 < target_fraction <= 1.0:
        raise ValueError("Playback peak fraction must be above 0 and at most 1")
    output = output_dir / "stimulus-normalized.wav"
    with wave.open(str(stimulus), "rb") as source:
        params = source.getparams()
        pcm = source.readframes(source.getnframes())
    if params.sampwidth != 2:
        raise ValueError("Playback peak normalization requires 16-bit PCM")
    sample_count = len(pcm) // 2
    samples = struct.unpack(f"<{sample_count}h", pcm)
    input_peak = max((abs(sample) for sample in samples), default=0)
    target_peak = round(32767 * target_fraction)
    gain = 1.0 if input_peak == 0 else target_peak / input_peak
    normalized = (
        max(-32768, min(32767, round(sample * gain))) for sample in samples
    )
    with wave.open(str(output), "wb") as destination:
        destination.setparams(params)
        destination.writeframes(
            struct.pack(f"<{sample_count}h", *normalized),
        )
    output_peak = 0 if input_peak == 0 else target_peak
    gain_db = 0.0 if gain <= 0 else 20 * math.log10(gain)
    return output, {
        "target_fraction": target_fraction,
        "input_peak": input_peak,
        "output_peak": output_peak,
        "gain_db": gain_db,
    }


def padded_wav_copy(
    stimulus: Path,
    output_dir: Path,
    *,
    leading_silence_seconds: float,
    trailing_silence_seconds: float,
) -> Path:
    if leading_silence_seconds < 0 or trailing_silence_seconds < 0:
        raise ValueError("Playback silence durations cannot be negative")
    if leading_silence_seconds == 0 and trailing_silence_seconds == 0:
        return stimulus

    output = output_dir / "stimulus-padded.wav"
    with wave.open(str(stimulus), "rb") as source:
        params = source.getparams()
        pcm = source.readframes(source.getnframes())
    bytes_per_frame = params.nchannels * params.sampwidth
    leading = b"\x00" * (
        round(params.framerate * leading_silence_seconds) * bytes_per_frame
    )
    trailing = b"\x00" * (
        round(params.framerate * trailing_silence_seconds) * bytes_per_frame
    )
    with wave.open(str(output), "wb") as padded:
        padded.setparams(params)
        padded.writeframes(leading + pcm + trailing)
    return output


def playback_copy(
    stimulus: Path,
    output_dir: Path,
    *,
    leading_silence_seconds: float = 1.0,
    trailing_silence_seconds: float = 0.5,
) -> Path:
    """Duplicate mono speech to every channel of the active computer sink."""
    source = padded_wav_copy(
        stimulus,
        output_dir,
        leading_silence_seconds=leading_silence_seconds,
        trailing_silence_seconds=trailing_silence_seconds,
    )
    wpctl = shutil.which("wpctl")
    ffmpeg = shutil.which("ffmpeg")
    if wpctl is None or ffmpeg is None:
        return source
    try:
        status = subprocess.run(
            [wpctl, "status"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        match = re.search(r"^\s*│?\s*\*\s+(\d+)\.", status, re.MULTILINE)
        if match is None:
            return source
        details = subprocess.run(
            [wpctl, "inspect", match.group(1)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        channel_match = re.search(r'audio\.channels = "(\d+)"', details)
        channels = int(channel_match.group(1)) if channel_match else 1
        if channels <= 1 or channels > 8:
            return source
        output = output_dir / f"stimulus-padded-{channels}ch.wav"
        pan = f"{channels}c|" + "|".join(
            f"c{channel}=c0" for channel in range(channels)
        )
        subprocess.run(
            [
                ffmpeg,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(source),
                "-filter_complex",
                f"pan={pan}",
                str(output),
            ],
            check=True,
        )
        return output
    except (OSError, ValueError, subprocess.CalledProcessError):
        return source


def run_physical(args: argparse.Namespace) -> int:
    output_dir = Path(args.output_dir).resolve()
    prepare_artifact_directory(output_dir)
    stimulus = output_dir / "stimulus.wav"
    device_log = output_dir / "device.log"
    report_path = output_dir / "report.json"
    synthesize(args.text, stimulus, args.speaker_id, args.speed)
    normalized_stimulus, peak_normalization = peak_normalized_wav_copy(
        stimulus,
        output_dir,
    )
    if args.phone_speaker:
        playback = padded_wav_copy(
            normalized_stimulus,
            output_dir,
            leading_silence_seconds=args.leading_silence_seconds,
            trailing_silence_seconds=args.trailing_silence_seconds,
        )
    else:
        playback = playback_copy(
            normalized_stimulus,
            output_dir,
            leading_silence_seconds=args.leading_silence_seconds,
            trailing_silence_seconds=args.trailing_silence_seconds,
        )
    test_case = "single"
    playback_start = playback_marker("playback_start", test_case)
    playback_end = playback_marker("playback_end", test_case)

    adb = select_adb(args.adb)
    serial = ensure_single_device(adb, args.serial)
    adb_prefix = [adb, "-s", serial]
    package_result = subprocess.run(
        [*adb_prefix, "shell", "pm", "path", APP_PACKAGE],
        capture_output=True,
        text=True,
    )
    if package_result.returncode != 0 or "package:" not in package_result.stdout:
        raise RuntimeError(f"Work Bench is not installed ({APP_PACKAGE})")

    required_log_tags = (
        "log.tag.WorkBenchTest",
        "log.tag.flutter",
        "log.tag.WorkBench",
    )
    previous_log_tags: dict[str, str] = {}
    log_handle = None
    log_process = None
    media_volume = None
    phone_volume = None
    wpctl = None
    previous_computer_volume = None
    try:
        for tag in required_log_tags:
            previous_log_tags[tag] = get_android_property(adb_prefix, tag)
            set_android_property(adb_prefix, tag, "V")
        subprocess.run([*adb_prefix, "logcat", "-c"], check=True)
        log_handle = device_log.open("w", encoding="utf-8")
        log_process = subprocess.Popen(
            [*adb_prefix, "logcat", "-v", "time"],
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            text=True,
        )
        media_volume = (
            get_media_volume(adb_prefix) if args.phone_speaker else None
        )
        if args.phone_speaker and media_volume is None:
            raise RuntimeError("Could not read the phone media-volume range")
        phone_volume = (
            None
            if media_volume is None
            else (
                args.phone_volume
                if args.phone_volume is not None
                else media_volume.at_fraction(args.computer_volume)
            )
        )
        wpctl = None if args.phone_speaker else require_tool("wpctl")
        previous_computer_volume = (
            None if wpctl is None else get_computer_volume(wpctl)
        )
        if wpctl is not None:
            set_computer_volume(wpctl, args.computer_volume)
        time.sleep(args.baseline_seconds)
        emit_android_test_marker(adb_prefix, "playback_start", test_case)
        try:
            if args.phone_speaker:
                remote = "/data/local/tmp/workbench-kokoro-test.wav"
                subprocess.run(
                    [*adb_prefix, "push", str(playback), remote],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
                subprocess.run(
                    [
                        *adb_prefix,
                        "shell",
                        "run-as",
                        APP_PACKAGE,
                        "cp",
                        remote,
                        "files/kokoro-test.wav",
                    ],
                    check=True,
                )
                assert phone_volume is not None
                set_media_volume(adb_prefix, phone_volume)
                subprocess.run(
                    [
                        *adb_prefix,
                        "shell",
                        "am",
                        "broadcast",
                        "-a",
                        f"{APP_PACKAGE}.PLAY_KOKORO_TEST",
                        "-p",
                        APP_PACKAGE,
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
                with wave.open(str(playback), "rb") as wav:
                    time.sleep(wav.getnframes() / wav.getframerate())
            else:
                player = args.player or require_tool("pw-play")
                subprocess.run([player, str(playback)], check=True)
        finally:
            emit_android_test_marker(adb_prefix, "playback_end", test_case)
        time.sleep(args.wait_after)
    finally:
        if media_volume is not None:
            try:
                set_media_volume(adb_prefix, media_volume.current)
            except subprocess.CalledProcessError:
                pass
        if wpctl is not None and previous_computer_volume is not None:
            try:
                set_computer_volume(wpctl, previous_computer_volume)
            except subprocess.CalledProcessError:
                pass
        if log_process is not None:
            log_process.terminate()
            try:
                log_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                log_process.kill()
                log_process.wait(timeout=5)
        if log_handle is not None:
            log_handle.close()
        for tag, value in previous_log_tags.items():
            try:
                set_android_property(adb_prefix, tag, value)
            except subprocess.CalledProcessError:
                pass

    log_text = device_log.read_text(encoding="utf-8", errors="replace")
    report = build_report(
        expected=args.text,
        log_text=log_text,
        baseline_count=max(1, math.floor(args.baseline_seconds)),
        max_wer=args.max_wer,
        min_activity_rise=args.min_activity_rise,
        min_frames_per_second=args.min_frames_per_second,
        playback_start_marker=playback_start,
        playback_end_marker=playback_end,
        playback_volume=args.computer_volume,
        leading_silence_seconds=args.leading_silence_seconds,
        trailing_silence_seconds=args.trailing_silence_seconds,
    )
    report_document = asdict(report)
    report_document["test_fixture"] = {
        "case": test_case,
        "expected_text": args.text,
        "speaker_id": args.speaker_id,
        "speaker_name": ENGLISH_SPEAKERS[args.speaker_id],
        "speed": args.speed,
        "playback_path": (
            "phone_speaker" if args.phone_speaker else "computer_speaker"
        ),
        "phone_volume_index": phone_volume,
        "phone_volume_range": (
            None
            if media_volume is None
            else [media_volume.minimum, media_volume.maximum]
        ),
        "peak_normalization": peak_normalization,
        "stimulus": wav_manifest(stimulus),
        "playback": wav_manifest(playback),
    }
    report_path.write_text(
        json.dumps(report_document, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(report_path.read_text(encoding="utf-8"))
    return 0 if report.passed else 2


def score_existing(args: argparse.Namespace) -> int:
    log_text = Path(args.log).read_text(encoding="utf-8", errors="replace")
    report = build_report(
        expected=args.text,
        log_text=log_text,
        baseline_count=args.baseline_count,
        max_wer=args.max_wer,
        min_activity_rise=args.min_activity_rise,
        min_frames_per_second=args.min_frames_per_second,
    )
    print(json.dumps(asdict(report), indent=2, ensure_ascii=False))
    return 0 if report.passed else 2


def add_scoring_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--max-wer", type=float, default=0.25)
    parser.add_argument("--min-activity-rise", type=float, default=30.0)
    parser.add_argument("--min-frames-per-second", type=float, default=90.0)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    commands.add_parser("prepare")

    generate = commands.add_parser("generate")
    generate.add_argument("--text", default=DEFAULT_TEXT)
    generate.add_argument("--output", required=True)
    generate.add_argument(
        "--speaker-id",
        type=int,
        choices=tuple(ENGLISH_SPEAKERS),
        default=0,
        help="English Kokoro voice: 0=af_maple, 1=af_sol, 2=bf_vale",
    )
    generate.add_argument("--speed", type=float, default=1.0)

    internal = commands.add_parser("_synthesize")
    internal.add_argument("--text", required=True)
    internal.add_argument("--output", required=True)
    internal.add_argument(
        "--speaker-id",
        type=int,
        choices=tuple(ENGLISH_SPEAKERS),
        required=True,
    )
    internal.add_argument("--speed", type=float, required=True)

    run = commands.add_parser("run")
    run.add_argument("--text", default=DEFAULT_TEXT)
    run.add_argument("--output-dir", required=True)
    run.add_argument(
        "--speaker-id",
        type=int,
        choices=tuple(ENGLISH_SPEAKERS),
        default=0,
        help="English Kokoro voice: 0=af_maple, 1=af_sol, 2=bf_vale",
    )
    run.add_argument("--speed", type=float, default=1.0)
    run.add_argument("--adb")
    run.add_argument("--serial")
    run.add_argument("--player")
    run.add_argument(
        "--computer-volume",
        type=float,
        default=0.90,
        help=(
            "Playback-volume fraction. Controls the computer sink or the "
            "phone media range; the original volume is always restored."
        ),
    )
    run.add_argument("--leading-silence-seconds", type=float, default=1.0)
    run.add_argument("--trailing-silence-seconds", type=float, default=0.5)
    run.add_argument(
        "--phone-speaker",
        action="store_true",
        help=(
            "Trigger the debug app's phone-speaker playback hook instead of "
            "the workstation sink; useful when the computer has no audible "
            "speaker near the glasses."
        ),
    )
    run.add_argument(
        "--phone-volume",
        type=int,
        help=(
            "Raw phone media-volume index override. By default the runner "
            "uses the same playback fraction as --computer-volume."
        ),
    )
    run.add_argument("--baseline-seconds", type=float, default=4.0)
    run.add_argument("--wait-after", type=float, default=12.0)
    add_scoring_arguments(run)

    score = commands.add_parser("score-log")
    score.add_argument("--text", default=DEFAULT_TEXT)
    score.add_argument("--log", required=True)
    score.add_argument("--baseline-count", type=int, default=4)
    add_scoring_arguments(score)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "prepare":
        prepare()
        return 0
    if args.command == "generate":
        synthesize(
            args.text,
            Path(args.output).resolve(),
            args.speaker_id,
            args.speed,
        )
        return 0
    if args.command == "_synthesize":
        _synthesize_internal(
            args.text,
            Path(args.output).resolve(),
            args.speaker_id,
            args.speed,
        )
        return 0
    if args.command == "run":
        return run_physical(args)
    if args.command == "score-log":
        return score_existing(args)
    raise AssertionError(args.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
