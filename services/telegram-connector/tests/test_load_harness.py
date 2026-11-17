"""The S2b load driver (load/run.py) still runs against the current connector:
a tiny run delivers every injected message, before and after a restart."""

import asyncio
import logging
import tempfile
import unittest

from load import run


class ProblemsCaptureTest(unittest.TestCase):
    """Negative control: a connector WARNING must be counted, not silently dropped
    (the slice-1 runs set root logging to ERROR, so their warnings are unmeasured)."""

    def test_connector_warning_is_counted_and_logging_restored(self):
        root = logging.getLogger()
        level, handlers = root.level, list(root.handlers)
        root.setLevel(logging.ERROR)
        try:
            QUIET = run.QUIET
            QUIET.append(True)
            try:
                with run.capture_problems() as problems:
                    logging.getLogger("telegram.account").warning("flood wait: 30 s on acc-1")
                    logging.getLogger("telegram.rails").error("delivery failed: 500")
                    logging.getLogger("telegram.account").info("connected: acc-1")
            finally:
                QUIET.pop()
            self.assertEqual(problems.counts, {"flood wait": 1, "delivery failed": 1})
            self.assertEqual(root.level, logging.ERROR)
            self.assertEqual(root.handlers, handlers)
        finally:
            root.setLevel(level)


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
        self.assertTrue(result["warnings_measured"])
        steady = result["steady"]
        self.assertLess(steady["rails_requests_steady_and_drain"], steady["rails_requests_cumulative_through_drain"])


if __name__ == "__main__":
    unittest.main()
