"""Gemini/Antigravity subscription usage reads agy's /usage JSON directly."""

from datetime import datetime, timedelta, timezone
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_soulshouse_usage():
    loader = importlib.machinery.SourceFileLoader(
        "soulshouse_usage_under_test",
        str(REPO_ROOT / "agent-runtime" / "soulshouse-usage"),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class AntigravityUsageTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {
            "HOME": str(self.root),
            "PATH": os.defpath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token",
            "CHAOS_HOME": str(self.root / "chaos"),
            "CHAOS_AGY_HOME": str(self.root / "agy-home"),
            "AGENT_IDENTITY_PATH": str(self.root / "identity"),
            "AGENT_REPO_PATH": str(self.root),
            "GEMINI_API_KEY": "synthetic-gemini-key",
            "GOOGLE_API_KEY": "synthetic-google-key",
        }, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "antigravity_usage_shim",
            REPO_ROOT / "agent-runtime" / "trigger_shim.py",
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)

    def sample_agy_payload(self):
        now = datetime.now(timezone.utc)
        five_hour_reset = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
        weekly_reset = (now + timedelta(days=5)).isoformat().replace("+00:00", "Z")
        return {
            "conversation_id": "",
            "status": "SUCCESS",
            "response": (
                f"Gemini Models\tWeekly Limit Remaining\t98%\t{weekly_reset}\n"
                f"Gemini Models\tFive Hour Limit Remaining\t94%\t{five_hour_reset}\n"
                f"Claude and GPT models\tWeekly Limit Remaining\t100%\t{weekly_reset}\n"
                f"Claude and GPT models\tFive Hour Limit Remaining\t100%\t{five_hour_reset}\n"
            ),
            "duration_seconds": 0,
            "num_turns": 0,
            "usage": {"total_tokens": 0},
            "command": {
                "name": "usage",
                "data": {
                    "groups": [
                        {
                            "name": "Gemini Models",
                            "buckets": [
                                {
                                    "id": "gemini-weekly",
                                    "name": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remaining_fraction": 0.9840726,
                                    "reset_time": weekly_reset,
                                },
                                {
                                    "id": "gemini-5h",
                                    "name": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remaining_fraction": 0.9412477,
                                    "reset_time": five_hour_reset,
                                },
                            ],
                        },
                        {
                            "name": "Claude and GPT models",
                            "buckets": [
                                {
                                    "id": "3p-weekly",
                                    "name": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remaining_fraction": 1,
                                    "reset_time": weekly_reset,
                                },
                                {
                                    "id": "3p-5h",
                                    "name": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remaining_fraction": 1,
                                    "reset_time": five_hour_reset,
                                },
                            ],
                        },
                    ],
                },
            },
        }

    def test_probe_antigravity_usage_uses_single_bounded_deadline_without_models_preflight(self):
        calls = []
        token_path = self.shim._antigravity_oauth_token_path()
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text("synthetic-oauth-token")

        def fake_run(cmd, **kwargs):
            calls.append((cmd, kwargs))
            return subprocess.CompletedProcess(cmd, 0, json.dumps(self.sample_agy_payload()), "")

        with patch.object(self.shim, "_agy_available", return_value=True), \
                patch.object(self.shim.subprocess, "run", side_effect=fake_run):
            payload = self.shim.probe_antigravity_usage("gemini", "gemini-4-neon")

        self.assertEqual(payload["command"]["name"], "usage")
        self.assertEqual(len(calls), 1)
        self.assertLess(self.shim.ANTIGRAVITY_USAGE_TIMEOUT_SECS, self.shim.SUBSCRIPTION_USAGE_TIMEOUT_SECS)

        usage_cmd, usage_kwargs = calls[0]
        self.assertEqual(usage_cmd, [
            self.shim.AGY_BIN,
            "--log-file",
            "/dev/null",
            "--print",
            "/usage",
            "--output-format",
            "json",
            "--print-timeout",
            f"{self.shim.ANTIGRAVITY_USAGE_TIMEOUT_SECS}s",
        ])
        self.assertEqual(usage_kwargs["timeout"], self.shim.ANTIGRAVITY_USAGE_TIMEOUT_SECS)
        self.assertIs(usage_kwargs["stdin"], subprocess.DEVNULL)
        env = usage_kwargs["env"]
        self.assertEqual(env["HOME"], str(self.root / "agy-home"))
        self.assertEqual(env["BROWSER"], "/bin/true")
        self.assertNotIn("GEMINI_API_KEY", env)
        self.assertNotIn("GOOGLE_API_KEY", env)
        self.assertNotIn("CHAOS_AGY_LOGIN_URL_PATH", env)

        # Signed-out token check fails immediately with zero subprocesses.
        token_path.unlink()
        with patch.object(self.shim, "_agy_available", return_value=True), \
                patch.object(self.shim.subprocess, "run", side_effect=fake_run):
            with self.assertRaises(RuntimeError):
                self.shim.probe_antigravity_usage("gemini", "gemini-4-neon")
        self.assertEqual(len(calls), 1)

    def test_normalizes_agy_usage_for_all_downstream_gemini_consumers(self):
        snapshot = self.shim.normalize_subscription_usage(
            self.sample_agy_payload(), "gemini", "gemini-4-neon"
        )
        self.assertEqual(snapshot["provider"], "gemini")
        self.assertEqual(snapshot["model"], "gemini-4-neon")
        self.assertEqual(snapshot["plan"], "Google AI")
        self.assertEqual(snapshot["source"], "cli")
        self.assertEqual(snapshot["status"], "available")
        self.assertEqual(
            [(w["id"], w["label"], w["remaining_percent"], w["blocking"]) for w in snapshot["windows"]],
            [
                ("gemini-5h", "Gemini 5-hour", 94.12, True),
                ("gemini-weekly", "Gemini weekly", 98.41, True),
                ("3p-5h", "Claude/GPT 5-hour", 100.0, False),
                ("3p-weekly", "Claude/GPT weekly", 100.0, False),
            ],
        )

        helper = load_soulshouse_usage()
        displayed = helper.display_windows(snapshot)
        self.assertEqual([w["display_label"] for w in displayed], ["5-hour", "Weekly"])
        now = datetime.now(timezone.utc)
        self.assertIsNotNone(helper.predicted_weekly_usage(displayed, now))

    def test_preserves_exhausted_gemini_pool_when_remaining_fraction_is_zero_or_omitted(self):
        for mode in ("zero", "omitted_omitempty", "disabled"):
            with self.subTest(mode=mode):
                payload = self.sample_agy_payload()
                five_hour = payload["command"]["data"]["groups"][0]["buckets"][1]
                if mode == "zero":
                    five_hour["remaining_fraction"] = 0.0
                elif mode == "omitted_omitempty":
                    reset_5h = five_hour["reset_time"]
                    reset_wk = payload["command"]["data"]["groups"][0]["buckets"][0]["reset_time"]
                    del five_hour["remaining_fraction"]
                    payload["response"] = (
                        f"Gemini Models\tWeekly Limit Remaining\t98%\t{reset_wk}\n"
                        f"Gemini Models\tFive Hour Limit Remaining\t0%\t{reset_5h}\n"
                    )
                else:
                    del five_hour["remaining_fraction"]
                    five_hour["disabled"] = True

                snapshot = self.shim.normalize_subscription_usage(
                    payload, "gemini", "gemini-4-carbon"
                )
                self.assertEqual(snapshot["status"], "limited")
                by_id = {w["id"]: w for w in snapshot["windows"]}
                self.assertEqual(by_id["gemini-5h"]["remaining_percent"], 0.0)
                self.assertTrue(by_id["gemini-5h"]["blocking"])

        # Exhausted third-party pool does not block a Gemini model.
        payload = self.sample_agy_payload()
        payload["command"]["data"]["groups"][1]["buckets"][0]["remaining_fraction"] = 0.0
        snapshot = self.shim.normalize_subscription_usage(payload, "gemini", "gemini-4-neon")
        self.assertEqual(snapshot["status"], "available")

    def test_codexbar_offline_placeholder_is_treated_as_unknown_not_available(self):
        offline_payload = {
            "source": "offline",
            "usage": {
                "loginMethod": "offline",
                "extraRateWindows": [
                    {
                        "id": "antigravity-offline-conversations",
                        "title": "Offline · 7 conversations",
                        "window": {"usedPercent": 0, "resetsAt": None},
                    }
                ],
            },
        }
        snapshot = self.shim.normalize_subscription_usage(
            offline_payload, "gemini", "gemini-4-carbon"
        )
        self.assertEqual(snapshot["status"], "unknown")
        self.assertEqual(snapshot["windows"], [])

    def test_subscription_usage_treats_malformed_nonfinite_and_unusable_pools_as_failed_refresh(self):
        bad_payloads = []

        groups_int = self.sample_agy_payload()
        groups_int["command"]["data"]["groups"] = 1
        bad_payloads.append(("groups_int", groups_int))

        buckets_int = self.sample_agy_payload()
        buckets_int["command"]["data"]["groups"][0]["buckets"] = 1
        bad_payloads.append(("buckets_int", buckets_int))

        claude_only = self.sample_agy_payload()
        claude_only["command"]["data"]["groups"] = [claude_only["command"]["data"]["groups"][1]]
        bad_payloads.append(("claude_only_for_gemini", claude_only))

        nan_fraction = self.sample_agy_payload()
        nan_fraction["command"]["data"]["groups"][0]["buckets"][0]["remaining_fraction"] = float("nan")
        bad_payloads.append(("nan_fraction", nan_fraction))

        inf_fraction = self.sample_agy_payload()
        inf_fraction["command"]["data"]["groups"][0]["buckets"][0]["remaining_fraction"] = float("inf")
        bad_payloads.append(("inf_fraction", inf_fraction))

        missing_reset = self.sample_agy_payload()
        for bucket in missing_reset["command"]["data"]["groups"][0]["buckets"]:
            bucket["reset_time"] = None
        bad_payloads.append(("missing_gemini_resets", missing_reset))

        for label, bad in bad_payloads:
            with self.subTest(case=label, cache="cold"):
                self.shim._subscription_usage_cache.clear()
                with patch.dict(self.shim.USAGE_PROBES, {"gemini": lambda _p, _m, b=bad: b}):
                    cold = self.shim.subscription_usage("gemini", "gemini-4-neon", refresh=True)
                self.assertEqual(cold["status"], "unknown")
                self.assertEqual(cold["windows"], [])
                self.assertEqual(self.shim._subscription_usage_cache, {})

            with self.subTest(case=label, cache="warm_last_good"):
                self.shim._subscription_usage_cache.clear()
                good = self.sample_agy_payload()
                with patch.dict(self.shim.USAGE_PROBES, {"gemini": lambda _p, _m, g=good: g}):
                    seeded = self.shim.subscription_usage("gemini", "gemini-4-neon", refresh=True)
                self.assertEqual(seeded["status"], "available")

                with patch.dict(self.shim.USAGE_PROBES, {"gemini": lambda _p, _m, b=bad: b}):
                    fallback = self.shim.subscription_usage("gemini", "gemini-4-neon", refresh=True)
                self.assertEqual(fallback, seeded)

        # Also verify raw JSON NaN from agy stdout is rejected by _antigravity_usage.
        token_path = self.shim._antigravity_oauth_token_path()
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text("synthetic-oauth-token")
        nan_stdout = '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":NaN,"reset_time":"2099-01-01T00:00:00Z"}]}]}}}'
        with patch.object(self.shim, "_agy_available", return_value=True), \
                patch.object(
                    self.shim.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(["agy"], 0, nan_stdout, ""),
                ):
            self.shim._subscription_usage_cache.clear()
            snap = self.shim.subscription_usage("gemini", "gemini-4-neon", refresh=True)
            self.assertEqual(snap["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
