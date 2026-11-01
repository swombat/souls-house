"""Credential-free unit tests: python3 -m unittest discover -s agent-runtime -p 'test_soulshouse_usage.py'."""

import contextlib
from datetime import datetime, timezone
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader(
    "soulshouse_usage", str(Path(__file__).with_name("soulshouse-usage"))
)
spec = importlib.util.spec_from_loader(loader.name, loader)
usage = importlib.util.module_from_spec(spec)
loader.exec_module(usage)


class Clock(datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 8, 31, tzinfo=timezone.utc)


class UsageTest(unittest.TestCase):
    def run_cli(self, payload, *args):
        output = io.StringIO()

        def respond(request, timeout):
            self.assertEqual(request.get_header("Authorization"), "Bearer synthetic")
            self.assertEqual(request.full_url, "https://usage.example/api/v1/subscription_usage")
            return io.StringIO(json.dumps(payload))

        with patch.dict(usage.os.environ, {
            "SOULSHOUSE_APP_URL": "https://usage.example",
            "SOULSHOUSE_BEARER_TOKEN": "synthetic",
        }, clear=True), patch.object(usage.sys, "argv", ["soulshouse-usage", *args]), \
                patch.object(usage, "datetime", Clock), \
                patch.object(usage.NO_REDIRECT_OPENER, "open", respond), \
                contextlib.redirect_stdout(output):
            self.assertEqual(usage.main(), 0)
        return output.getvalue()

    def test_openai_windows_have_no_inferred_duration_or_projection(self):
        short = dict(id="session", label="Session", remaining_percent=60,
                     resets_at="2026-08-31T04:00:00Z")
        long = dict(id="weekly", label="Weekly", remaining_percent=30,
                    resets_at="2026-09-06T00:00:00Z")
        cases = [
            [short],
            [dict(long, id="session", label="Session")],
            [short, long],
            [dict(short, id="primary", label="Primary", resets_at=None)],
        ]
        for raw_windows in cases:
            with self.subTest(windows=raw_windows):
                payload = dict(provider="openai", windows=raw_windows)
                windows = usage.display_windows(payload)
                self.assertEqual(len(windows), len(raw_windows))
                for window, raw in zip(windows, raw_windows):
                    self.assertRegex(window["display_label"], r"^Allowance(?: \d+)?$")
                    self.assertEqual(window["resets_at"], raw["resets_at"])
                self.assertIsNone(usage.predicted_weekly_usage(windows, Clock.now()))
                self.assertEqual(json.loads(self.run_cli(payload, "--json")), payload)
                human = self.run_cli(payload)
                self.assertNotIn("Predicted", human)
                self.assertNotIn("Weekly", human)
                for raw in raw_windows:
                    self.assertIn(f'{raw["remaining_percent"]}% left', human)
                    reset = usage.reset_description(raw["resets_at"], Clock.now())
                    if reset:
                        self.assertIn(reset, human)

    def test_spark_family_is_selected_without_duration_labels(self):
        base = dict(remaining_percent=60, resets_at="2026-09-06T00:00:00Z")
        payload = dict(provider="openai", model="codex-spark", windows=[
            dict(base, label="Session"),
            dict(base, label="codex-spark session"),
            dict(base, label="codex-spark weekly"),
        ])
        self.assertEqual(len(usage.display_windows(payload)), 2)
        self.assertEqual(json.loads(self.run_cli(payload, "--json")), payload)
        self.assertNotIn("Predicted", self.run_cli(payload))
        payload["model"] = "other"
        self.assertEqual(len(usage.display_windows(payload)), 1)

    def test_anthropic_verified_weekly_projection_is_preserved(self):
        payload = dict(provider="anthropic", windows=[
            dict(label="Session", remaining_percent=60, resets_at="2026-08-31T02:30:00Z"),
            dict(label="Weekly", remaining_percent=60, resets_at="2026-09-03T12:00:00Z"),
        ])
        self.assertEqual([w["display_label"] for w in usage.display_windows(payload)],
                         ["5-hour", "Weekly"])
        self.assertEqual(json.loads(self.run_cli(payload, "--json"))[
            "predicted_weekly_usage_percent"], 80)
        self.assertIn("Predicted usage: 80%", self.run_cli(payload))


if __name__ == "__main__":
    unittest.main()
