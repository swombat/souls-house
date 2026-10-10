import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import boundary


def protocol(status="ok", items=None):
    return json.dumps({"status": status, "items": items or []}).encode()


class BoundaryTests(unittest.TestCase):
    def test_real_absent_empty_and_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(boundary.capability_notice(directory), "")
            path = Path(directory) / "runtime-requirements.yml"
            path.write_text("pip: []")
            self.assertEqual(boundary.capability_notice(directory), "")
            path.write_text("")
            self.assertEqual(boundary.capability_notice(directory), boundary.INVALID)

    def test_reason_never_crosses_worker_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "runtime-requirements.yml").write_text(
                "pip:\n- name: unreviewed\n  reason: PRIVATE_SENTINEL\n"
            )
            raw = boundary._capture([
                sys.executable, str(Path(boundary.__file__).with_name("worker.py")),
                directory,
            ])
            self.assertNotIn(b"PRIVATE_SENTINEL", raw)
            self.assertIn("unsupported: pip:unreviewed", boundary.render(raw))
            self.assertNotIn("PRIVATE_SENTINEL", boundary.render(raw))

    def test_found_silent_and_mixed_states(self):
        found = {"channel": "pip", "name": "numpy", "state": "found"}
        self.assertEqual(boundary.render(protocol(items=[found])), "")
        notice = boundary.render(protocol(items=[
            found, {"channel": "apt", "name": "ffmpeg", "state": "missing"},
            {"channel": "pip", "name": "scipy", "state": "error"},
            {"channel": "pip", "name": "other", "state": "unsupported"},
        ]))
        self.assertIn("missing: apt:ffmpeg", notice)
        self.assertIn("error: pip:scipy", notice)
        self.assertIn(boundary.DISCLAIMER, notice)
        self.assertNotIn("numpy", notice)

    def test_malformed_untrusted_protocol_fails_closed(self):
        bad = [
            b"{", b'{"status":"absent","status":"ok","items":[]}',
            b"[" * 2000 + b"]" * 2000,
            protocol("invalid", [{"reason": "SECRET"}]),
            protocol(items=[{"channel": "pip", "name": "evil\nINSTRUCTION",
                             "state": "unsupported"}]),
            protocol(items=[{"channel": "pip", "name": "numpy", "state": "unsupported"}]),
            protocol(items=[{"channel": "pip", "name": "other", "state": "found"}]),
            protocol(items=[{"channel": [], "name": "numpy", "state": "found"}]),
        ]
        for raw in bad:
            with self.subTest(raw=raw), patch.object(boundary, "_capture", return_value=raw):
                self.assertEqual(boundary.capability_notice("/synthetic"), boundary.FAILURE)

    def test_real_timeout_and_oversize(self):
        launched = []
        real_popen = boundary.subprocess.Popen

        def tracked_popen(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            launched.append(process)
            return process

        for script in ("import time; time.sleep(10)",
                       "import sys; sys.stdout.write('x' * 1000000); sys.stdout.flush()"):
            start = time.monotonic()
            with patch.object(boundary.subprocess, "Popen", side_effect=tracked_popen), self.assertRaises(ValueError):
                boundary._capture([sys.executable, "-c", script], timeout=0.2)
            self.assertLess(time.monotonic() - start, 2)
            self.assertIsNotNone(launched[-1].returncode)

    def test_worker_nonzero_and_launch_failure(self):
        with self.assertRaises(ValueError):
            boundary._capture([sys.executable, "-c", "raise SystemExit(7)"])
        with patch.object(boundary, "_capture", side_effect=FileNotFoundError):
            self.assertEqual(boundary.capability_notice("/synthetic"), boundary.FAILURE)

    def test_notice_truncation_is_explicit(self):
        items = [{"channel": "pip", "name": "x" * 120 + str(i),
                  "state": "unsupported"} for i in range(32)]
        notice = boundary.render(protocol(items=items))
        self.assertLessEqual(len(notice.encode()), boundary.MAX_NOTICE)
        self.assertIn("[truncated]", notice)
        self.assertTrue(notice.endswith(boundary.DISCLAIMER))


if __name__ == "__main__":
    unittest.main()
