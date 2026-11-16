"""The S2b load driver (load/run.py) still runs against the current connector:
a tiny run delivers every injected message, before and after a restart."""

import asyncio
import tempfile
import unittest

from load import run


class LoadHarnessTest(unittest.TestCase):
    def test_tiny_run_delivers_everything(self):
        out = tempfile.mkdtemp(prefix="tg-load-test-")
        args = run.parse(["--label", "tiny", "--accounts", "3", "--duration", "2", "--busy-per-minute", "60",
                          "--abusive-per-minute", "120", "--abusive-searches-per-minute", "60",
                          "--history-per-day", "1", "--abusive-history-per-day", "2", "--drain-timeout", "30",
                          "--profile-restart", "0", "--out", out, "--quiet"])
        result = asyncio.run(run.main(args))
        self.assertEqual(result["onboard"]["connected"], 3)
        self.assertEqual(result["onboard"]["accounts_backfilled"], 3)
        for group in result["steady"]["delivery_latency_s"].values():
            self.assertEqual(group["undelivered"], 0)
        for group in result["restart"]["delivery"].values():
            self.assertEqual(group["undelivered"], 0)
        self.assertEqual(result["warnings"], {})


if __name__ == "__main__":
    unittest.main()
