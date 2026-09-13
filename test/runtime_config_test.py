import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

RUNTIME = Path(__file__).resolve().parents[1] / "agent-runtime"


class RuntimeConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "config.toml"
        entrypoint = (RUNTIME / "entrypoint.sh").read_text()
        # Run the actual boot config section, without starting a resident or
        # touching real volumes, credentials, hooks, or ownership.
        self.script = entrypoint.split('touch "$CHAOS_CONFIG"', 1)[1].split(
            'chown 1000:1000 "$CHAOS_CONFIG"', 1
        )[0]
        self.script = 'set -e\ntouch "$CHAOS_CONFIG"\n' + self.script

    def install(self):
        return subprocess.run(
            ["sh", "-c", self.script],
            env={**os.environ, "CHAOS_CONFIG": str(self.path)},
            capture_output=True,
            text=True,
        )

    def test_fresh_config_enables_control_and_keeps_provider_defaults(self):
        self.assertEqual(0, self.install().returncode)
        config = tomllib.loads(self.path.read_text())
        self.assertEqual("bounded", config["agent_compaction_control"])
        self.assertEqual({"gemini", "openrouter"}, set(config["model_providers"]))

    def test_existing_config_gets_root_default_and_boot_is_idempotent(self):
        original = b'# resident notes\r\n[model_providers.custom]\r\nname = "Custom"\r\n'
        self.path.write_bytes(original)
        self.assertEqual(0, self.install().returncode)
        first = self.path.read_bytes()
        self.assertIn(original, first)
        self.assertEqual("bounded", tomllib.loads(first.decode())["agent_compaction_control"])
        self.assertEqual(0, self.install().returncode)
        self.assertEqual(first, self.path.read_bytes())

    def test_explicit_resident_choice_is_preserved(self):
        for choice in ("disabled", "bounded"):
            with self.subTest(choice=choice):
                self.path.write_text(f'"agent_compaction_control" = "{choice}" # chosen\n')
                self.assertEqual(0, self.install().returncode)
                first = self.path.read_bytes()
                self.assertEqual(choice, tomllib.loads(first.decode())["agent_compaction_control"])
                self.assertEqual(0, self.install().returncode)
                self.assertEqual(first, self.path.read_bytes())

    def test_invalid_config_is_not_overwritten(self):
        original = b'[broken\n'
        self.path.write_bytes(original)
        self.assertNotEqual(0, self.install().returncode)
        self.assertEqual(original, self.path.read_bytes())
