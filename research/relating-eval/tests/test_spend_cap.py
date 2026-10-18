"""Bug 1: retries must be re-admitted against the spend cap before every paid attempt."""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from _helpers import or_payload

import common


class SpendCapPerAttemptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": "test-key-not-real"})
        env.start()
        self.addCleanup(env.stop)
        sleep = mock.patch.object(common.time, "sleep")
        sleep.start()
        self.addCleanup(sleep.stop)

    def _run(self, finish_reason):
        client = common.Client(Path(self.tmp.name), max_spend_usd=0.20, default_reserve_usd=0.10)
        replies = [or_payload("", 0.09, finish_reason) for _ in range(client.max_attempts)]
        with mock.patch.object(common.urllib.request, "urlopen", side_effect=replies) as urlopen:
            with self.assertRaises(common.BudgetExceeded):
                client.chat("vendor/model", [{"role": "user", "content": "hi"}], role="candidate")
        return client, urlopen.call_count

    def test_empty_reply_retries_stop_at_cap(self):
        # Before the fix: seven charged requests, $0.63 against a $0.20 cap.
        client, n = self._run("stop")
        self.assertLessEqual(client.spent, 0.20 + 1e-9)
        self.assertEqual(n, 2)
        self.assertAlmostEqual(client.reserved, 0.0)

    def test_truncated_retry_with_doubled_budget_stops_at_cap(self):
        # A retry with doubled max_tokens reserves double, so it is not admitted at $0.09 + $0.18.
        client, n = self._run("length")
        self.assertLessEqual(client.spent, 0.20 + 1e-9)
        self.assertEqual(n, 1)
        self.assertAlmostEqual(client.reserved, 0.0)

    def test_successful_retry_under_cap_still_works(self):
        client = common.Client(Path(self.tmp.name), max_spend_usd=1.0, default_reserve_usd=0.10)
        with mock.patch.object(common.urllib.request, "urlopen",
                               side_effect=[or_payload("", 0.05), or_payload("hello", 0.05)]):
            text, meta = client.chat("vendor/model", [{"role": "user", "content": "hi"}], role="candidate")
        self.assertEqual(text, "hello")
        self.assertAlmostEqual(client.spent, 0.10)
        self.assertAlmostEqual(client.reserved, 0.0)


if __name__ == "__main__":
    unittest.main()
