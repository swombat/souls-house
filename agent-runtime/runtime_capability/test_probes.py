import subprocess
import sys
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from manifest import Declaration, validate
from probes import PROBE_SECONDS, probe


class ProbeTests(unittest.TestCase):
    def declaration(self, channel, name):
        return Declaration(channel, name, True)

    def test_executable_presence_never_runs_ffmpeg(self):
        with patch("probes.shutil.which", return_value="/usr/bin/ffmpeg"), \
                patch("probes.subprocess.run") as run:
            self.assertEqual(probe(self.declaration("apt", "ffmpeg")).state, "found")
            run.assert_not_called()
        with patch("probes.shutil.which", return_value=None):
            self.assertEqual(probe(self.declaration("apt", "ffmpeg")).state, "missing")

    def test_numpy_apt_satisfies_pip_declaration(self):
        declarations = validate(b"""
apt:
  - {name: ffmpeg, reason: PRIVATE}
pip:
  - {name: numpy, reason: PRIVATE}
  - {name: scipy, reason: PRIVATE}
""")
        with patch("probes.shutil.which", return_value="/usr/bin/ffmpeg"), \
                patch("probes.subprocess.run", side_effect=[
                    subprocess.CompletedProcess([], 0),
                    subprocess.CompletedProcess([], 3),
                ]):
            results = [probe(d) for d in declarations]
        self.assertEqual([r.state for r in results], ["found", "found", "missing"])
        self.assertNotIn("PRIVATE", repr(results))

    def test_broken_module_is_found_without_importing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "numpy.py").write_text(
                "raise RuntimeError('synthetic broken installation')\n"
            )
            with patch.dict(os.environ, {"PYTHONPATH": directory}):
                self.assertEqual(
                    probe(self.declaration("pip", "numpy")).state, "found"
                )
                imported = subprocess.run(
                    [sys.executable, "-c", "import numpy"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
            self.assertNotEqual(imported.returncode, 0)

    def test_fixed_interpreter_and_bounded_silent_no_shell_call(self):
        with patch("probes.subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as run:
            probe(self.declaration("pip", "numpy"))
        args, kwargs = run.call_args
        self.assertEqual(args[0][0], sys.executable)
        self.assertEqual(args[0][1], "-c")
        self.assertIn("find_spec('numpy')", args[0][2])
        self.assertEqual(kwargs["timeout"], PROBE_SECONDS)
        self.assertFalse(kwargs["shell"])
        for stream in ("stdin", "stdout", "stderr"):
            self.assertEqual(kwargs[stream], subprocess.DEVNULL)

    def test_errors_are_not_absence(self):
        for outcome in [
            subprocess.CompletedProcess([], 1),
            subprocess.CompletedProcess([], -9),
            subprocess.TimeoutExpired(["PRIVATE"], 1),
            OSError("PRIVATE"),
        ]:
            with self.subTest(outcome=outcome):
                with patch("probes.subprocess.run") as run:
                    if isinstance(outcome, Exception):
                        run.side_effect = outcome
                    else:
                        run.return_value = outcome
                    result = probe(self.declaration("pip", "scipy"))
                self.assertEqual(result.state, "error")
                self.assertNotIn("PRIVATE", repr(result))

    def test_unreviewed_names_never_run_even_with_forged_supported_flag(self):
        with patch("probes.subprocess.run") as run, patch("probes.shutil.which") as which:
            for channel, name in [("pip", "os"), ("apt", "numpy"), ("pip", "$(bad)")]:
                self.assertEqual(probe(self.declaration(channel, name)).state, "unsupported")
            run.assert_not_called()
            which.assert_not_called()


if __name__ == "__main__":
    unittest.main()
