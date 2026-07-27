#!/usr/bin/env python3
"""Run repeated physical Kokoro turns while sampling both Android processes."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

APP_PACKAGE = "dev.opensourceglasses.even_g2_r1_poc"
FIXED_TEXT = (
    "Work Bench audio safety check number seven. "
    "The glasses should transcribe every word."
)
MINIMUM_SECONDS = 15 * 60
CORRECTION_COMPLETE = re.compile(
    r"\[WorkBench\]\[Correction\] state=completed\b.*\bsegment=(\S+)"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--duration-seconds", type=int, default=MINIMUM_SECONDS)
    parser.add_argument("--wait-after", type=float, default=30)
    parser.add_argument("--phone-speaker", action="store_true")
    return parser.parse_args()


def run(
    command: list[str],
    *,
    check: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        capture_output=capture_output,
        text=True,
    )


def adb(args: argparse.Namespace, *command: str) -> subprocess.CompletedProcess[str]:
    return run([args.adb, "-s", args.serial, *command], check=False)


def sample_device(args: argparse.Namespace, elapsed_seconds: float) -> dict[str, object]:
    meminfo = adb(args, "shell", "dumpsys", "meminfo", APP_PACKAGE).stdout
    battery = adb(args, "shell", "dumpsys", "battery").stdout
    gpu = adb(args, "shell", "dumpsys", "gpu").stdout
    processes = adb(
        args,
        "shell",
        "ps",
        "-A",
        "-o",
        "PID,NAME,RSS",
    ).stdout
    process_rows = [
        line.strip()
        for line in processes.splitlines()
        if APP_PACKAGE in line
    ]
    process_rss_kb: dict[str, int] = {}
    process_pids: dict[str, int] = {}
    for row in process_rows:
        fields = row.split()
        if len(fields) != 3 or not fields[0].isdigit() or not fields[2].isdigit():
            continue
        process_pids[fields[1]] = int(fields[0])
        process_rss_kb[fields[1]] = int(fields[2])
    gemma_pid = process_pids.get(f"{APP_PACKAGE}:gemma")
    gemma_gpu_memory = (
        re.search(rf"^Proc {gemma_pid} total:\s*(\d+)$", gpu, re.MULTILINE)
        if gemma_pid is not None
        else None
    )
    total_pss = re.search(r"TOTAL PSS:\s*(\d+)", meminfo)
    total_rss = re.search(r"TOTAL RSS:\s*(\d+)", meminfo)
    total_swap = re.search(r"TOTAL SWAP PSS:\s*(\d+)", meminfo)
    temperature = re.search(r"temperature:\s*(\d+)", battery)
    return {
        "at": datetime.now(timezone.utc).isoformat(),
        "elapsedSeconds": round(elapsed_seconds, 3),
        "totalPssKb": int(total_pss.group(1)) if total_pss else None,
        "totalRssKb": int(total_rss.group(1)) if total_rss else None,
        "totalSwapPssKb": int(total_swap.group(1)) if total_swap else None,
        "batteryTemperatureTenthsC": (
            int(temperature.group(1)) if temperature else None
        ),
        "processRssKb": process_rss_kb,
        "gemmaGpuMemoryBytes": (
            int(gemma_gpu_memory.group(1)) if gemma_gpu_memory else None
        ),
        "processes": process_rows,
    }


def main() -> int:
    args = parse_args()
    if args.duration_seconds < MINIMUM_SECONDS:
        raise SystemExit("Correction soak duration must be at least 900 seconds.")
    repository = Path(__file__).resolve().parent.parent
    output = args.output_dir.resolve()
    if output == repository or repository in output.parents:
        raise SystemExit("Soak evidence must be stored outside the repository.")
    if output.exists():
        raise SystemExit("Soak output directory must be new.")
    output.mkdir(parents=True)

    state = adb(args, "get-state").stdout.strip()
    if state != "device":
        raise SystemExit("The selected Android device is not connected and authorized.")
    if adb(args, "shell", "pm", "path", APP_PACKAGE).returncode != 0:
        raise SystemExit("Install Work Bench before running the soak.")

    runner = (
        repository
        / ".agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_g2_loop.py"
    )
    started_at = datetime.now(timezone.utc)
    started = time.monotonic()
    deadline = started + args.duration_seconds
    trials: list[dict[str, object]] = []
    memory_samples: list[dict[str, object]] = []
    memory_path = output / "memory.jsonl"
    trial_number = 0

    while time.monotonic() < deadline:
        trial_number += 1
        elapsed = time.monotonic() - started
        memory_sample = sample_device(args, elapsed)
        memory_samples.append(memory_sample)
        with memory_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(memory_sample) + "\n")
        trial_dir = output / f"trial-{trial_number:03d}"
        command = [
            sys.executable,
            str(runner),
            "run",
            "--serial",
            args.serial,
            "--adb",
            args.adb,
            "--text",
            FIXED_TEXT,
            "--output-dir",
            str(trial_dir),
            "--wait-after",
            str(args.wait_after),
        ]
        if args.phone_speaker:
            command.append("--phone-speaker")
        trial_started = time.monotonic()
        completed = run(command, check=False, capture_output=False)
        device_log = trial_dir / "device.log"
        log_text = (
            device_log.read_text(encoding="utf-8", errors="replace")
            if device_log.exists()
            else ""
        )
        correction = CORRECTION_COMPLETE.search(log_text)
        trials.append(
            {
                "trial": trial_number,
                "runnerPassed": completed.returncode == 0,
                "correctionCompleted": correction is not None,
                "elapsedSeconds": round(time.monotonic() - trial_started, 3),
            }
        )

    elapsed = time.monotonic() - started
    final_memory_sample = sample_device(args, elapsed)
    memory_samples.append(final_memory_sample)
    with memory_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(final_memory_sample) + "\n")
    passed = sum(
        1
        for trial in trials
        if trial["runnerPassed"] and trial["correctionCompleted"]
    )
    summary = {
        "startedAt": started_at.isoformat(),
        "durationSeconds": round(elapsed, 3),
        "minimumDurationSeconds": MINIMUM_SECONDS,
        "trials": trials,
        "completePasses": passed,
        "passRatio": passed / len(trials) if trials else 0,
        "memory": {
            "sampleCount": len(memory_samples),
            "first": memory_samples[0] if memory_samples else None,
            "last": memory_samples[-1] if memory_samples else None,
        },
    }
    (output / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )
    if elapsed < MINIMUM_SECONDS or passed != len(trials):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
