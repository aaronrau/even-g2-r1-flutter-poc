#!/usr/bin/env python3

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "kokoro_turn_suite.py"
SPEC = importlib.util.spec_from_file_location("kokoro_turn_suite", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def line(second: float, message: str) -> str:
    whole = int(second)
    millis = round((second - whole) * 1000)
    return f"07-25 12:00:{whole:02d}.{millis:03d} D/flutter: {message}"


class TurnSuiteTest(unittest.TestCase):
    def test_default_cases_cover_requested_sequence(self) -> None:
        cases = {case.name: case for case in MODULE.CASES}
        self.assertEqual(cases["long_continuous"].expected_turns, 1)
        self.assertEqual(cases["short_continuation"].silence_seconds, 0.4)
        self.assertEqual(cases["short_continuation"].expected_turns, 1)
        self.assertEqual(cases["separated_questions"].silence_seconds, 2.0)
        self.assertEqual(cases["separated_questions"].expected_turns, 3)

    def test_suite_uses_the_validated_playback_fixture_defaults(self) -> None:
        args = MODULE.parser().parse_args(["--output-dir", "/tmp/test-suite"])
        self.assertEqual(args.computer_volume, 0.90)
        self.assertEqual(args.leading_silence_seconds, 1.0)
        self.assertEqual(args.trailing_silence_seconds, 0.5)

    def test_duration_and_boundary_profiles_cover_extremes(self) -> None:
        durations = {case.name: case for case in MODULE.DURATION_CASES}
        boundaries = {case.name: case for case in MODULE.BOUNDARY_CASES}
        self.assertEqual(durations["duration_clip_100ms"].expected_turns, 0)
        self.assertIsNone(
            durations["duration_clip_300ms_characterize"].expected_turns
        )
        self.assertIsNone(
            durations["duration_clip_800ms_characterize"].expected_turns
        )
        self.assertIsNone(
            durations["duration_clip_650ms_characterize"].expected_turns
        )
        self.assertEqual(
            len(durations["duration_sixty_seconds"].utterances),
            13,
        )
        self.assertEqual(boundaries["gap_1200ms_merge"].expected_turns, 1)
        self.assertIsNone(
            boundaries["gap_1450ms_characterize"].expected_turns
        )
        self.assertIsNone(
            boundaries["gap_1500ms_characterize"].expected_turns
        )
        self.assertEqual(boundaries["gap_1800ms_split"].expected_turns, 2)

    def test_center_clip_has_exact_requested_length(self) -> None:
        pcm = bytes(range(100))
        clipped = MODULE._center_clip_pcm(pcm, sample_rate=10, seconds=2)
        self.assertEqual(len(clipped), 40)
        self.assertEqual(clipped, pcm[30:70])

    def test_center_clip_rejects_an_invalid_longer_request(self) -> None:
        with self.assertRaises(RuntimeError):
            MODULE._center_clip_pcm(
                bytes(range(100)),
                sample_rate=10,
                seconds=6,
            )

    def test_case_requires_endpoint_buffer_queue_and_order(self) -> None:
        case = MODULE.TurnCase(
            name="unit",
            utterances=("Where is my red book?",),
            silence_seconds=0.0,
            expected_turns=1,
        )
        segment = "turn-1"
        start = MODULE.loop.playback_marker("playback_start", case.name)
        end = MODULE.loop.playback_marker("playback_end", case.name)
        log = "\n".join(
            [
                line(
                    0.0,
                    "[Even G2/R1][Audio] 32.0 kbit/s • "
                    "100 frames/s • level 5/255",
                ),
                line(0.5, start),
                line(
                    1.0,
                    "[Even G2/R1][Audio] 32.0 kbit/s • "
                    "100 frames/s • level 90/255",
                ),
                line(
                    2.0,
                    f"[WorkBench][VAD] state=speech_started segment={segment}",
                ),
                line(
                    2.0,
                    "[WorkBench][TranscriptUI] state=cleared "
                    f"reason=speech_started segment={segment}",
                ),
                line(2.5, end),
                line(
                    3.0,
                    "[WorkBench][VAD] state=speech_ending "
                    f"segment={segment} delay_ms=1000",
                ),
                line(
                    4.0,
                    "[WorkBench][VAD] state=buffer_cleared "
                    f"segment={segment} bytes=64000 next=ready",
                ),
                line(
                    4.0,
                    "[WorkBench][VAD] state=speech_ended "
                    f"segment={segment} audio_ms=1000",
                ),
                line(
                    4.0,
                    "[WorkBench][Transcription] state=queued "
                    f"segment={segment} pending=1",
                ),
                line(
                    4.1,
                    "[WorkBench][Transcription] state=processing "
                    f"segment={segment}",
                ),
                line(
                    4.2,
                    "[WorkBench][Transcript][FINAL] "
                    f"segment={segment} text=Where is my red book",
                ),
            ]
        )
        result = MODULE.analyze_case(
            case,
            log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            playback_start_marker=start,
            playback_end_marker=end,
        )
        self.assertTrue(result.passed)
        self.assertTrue(result.checks["playback_boundary"])
        self.assertAlmostEqual(result.turns[0].endpoint_seconds, 1.0)
        self.assertEqual(result.turns[0].endpoint_audio_ms, 1000)
        self.assertAlmostEqual(
            result.turns[0].queue_to_final_seconds,
            0.2,
        )

    def test_prior_turn_words_are_detected_in_later_transcript(self) -> None:
        leaked = MODULE._leaked_prior_words(
            "When does the train leave?",
            "When does the red book train leave?",
            ("Where is my red book?",),
        )
        self.assertEqual(leaked, {"book"})


if __name__ == "__main__":
    unittest.main()
