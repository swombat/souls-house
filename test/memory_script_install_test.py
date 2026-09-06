import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "agent-runtime"
spec = importlib.util.spec_from_file_location("installer", RUNTIME / "install_memory_scripts.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class MemoryScriptInstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / "stock"
        self.live = Path(self.tmp.name) / "automation"
        self.source.mkdir()
        self.live.mkdir()
        self.stock(b"stock v1\n")

    def stock(self, content):
        for name in installer.SCRIPTS:
            (self.source / name).write_bytes(content)

    def install(self):
        return installer.install(self.source, self.live)

    def test_new_install_and_unmodified_upgrade(self):
        self.assertEqual([], self.install())
        self.stock(b"stock v2\n")
        self.assertEqual([], self.install())
        for name in installer.SCRIPTS:
            self.assertEqual(b"stock v2\n", (self.live / name).read_bytes())
            self.assertEqual(b"stock v2\n", (self.live / ".house-stock" / name).read_bytes())
            self.assertEqual(0o755, (self.live / name).stat().st_mode & 0o777)

    def test_unknown_baseline_preserves_edits_and_does_not_invent_ancestor(self):
        for name in installer.SCRIPTS:
            (self.live / name).write_bytes(b"older stock + resident edits\n")
        for _ in range(2):
            self.assertEqual(list(installer.SCRIPTS), self.install())
        for name in installer.SCRIPTS:
            self.assertEqual(b"older stock + resident edits\n", (self.live / name).read_bytes())
            self.assertFalse((self.live / ".house-stock" / name).exists())
            self.assertEqual(b"stock v1\n", (self.live / (name + ".upstream")).read_bytes())
        self.assertIn("baseline is unknown", (self.live / "HOUSE-HOOK-UPDATES.md").read_text())

    def test_existing_current_stock_establishes_baseline(self):
        for name in installer.SCRIPTS:
            (self.live / name).write_bytes(b"stock v1\n")
        self.assertEqual([], self.install())
        self.stock(b"stock v2\n")
        self.assertEqual([], self.install())

    def test_successive_stock_updates_keep_real_ancestor_and_active_edits(self):
        self.install()
        name = installer.SCRIPTS[0]
        (self.live / name).write_bytes(b"resident changes\n")
        for version in (b"stock v2\n", b"stock v3\n"):
            self.stock(version)
            self.assertEqual([name], self.install())
            self.assertEqual(b"resident changes\n", (self.live / name).read_bytes())
            self.assertEqual(b"stock v1\n", (self.live / ".house-stock" / name).read_bytes())
            self.assertEqual(version, (self.live / (name + ".upstream")).read_bytes())
        # An explicit return to current stock resumes automatic updates.
        (self.live / name).write_bytes(b"stock v3\n")
        self.assertEqual([], self.install())
        self.assertFalse((self.live / (name + ".upstream")).exists())
        self.assertFalse((self.live / "HOUSE-HOOK-UPDATES.md").exists())
        self.stock(b"stock v4\n")
        self.assertEqual([], self.install())
        self.assertEqual(b"stock v4\n", (self.live / name).read_bytes())

    def test_symlink_is_preserved_even_when_target_matches_stock(self):
        name = installer.SCRIPTS[0]
        target = Path(self.tmp.name) / "resident-owned"
        target.write_bytes(b"stock v1\n")
        (self.live / name).symlink_to(target)
        self.assertEqual([name], self.install())
        self.stock(b"stock v2\n")
        self.assertEqual([name], self.install())
        self.assertTrue((self.live / name).is_symlink())
        self.assertEqual(b"stock v1\n", target.read_bytes())

    def test_boot_merge_keeps_one_active_preserved_hook_and_real_prompt(self):
        # Execute actual stock + a synthetic resident addition, not a grep count.
        for name in installer.SCRIPTS:
            (self.source / name).write_bytes((RUNTIME / name).read_bytes())
        name = installer.SCRIPTS[0]
        (self.live / name).write_bytes((self.source / name).read_bytes().replace(
            b"from __future__ import annotations",
            b'from __future__ import annotations\nprint("resident addition", file=__import__("sys").stderr)', 1))
        config = Path(self.tmp.name) / "hooks.json"
        for _ in range(2):
            self.install()
            subprocess.run(["python3", str(RUNTIME / "install_memory_hooks.py"), str(config)], check=True)
        hooks = json.loads(config.read_text())["hooks"]
        self.assertEqual(1, len(hooks["Stop"]))
        self.assertEqual(1, len(hooks["Stop"][0]["hooks"]))
        self.assertEqual(f"python3 /home/agent/identity/automation/{name}", hooks["Stop"][0]["hooks"][0]["command"])
        import os
        env = dict(os.environ, AGENT_IDENTITY_PATH=str(Path(self.tmp.name) / "identity"))
        result = subprocess.run(["python3", str(self.live / name)], input='{"last_assistant_message":"Synthetic meaningful turn"}', text=True, capture_output=True, env=env)
        self.assertEqual(2, result.returncode, result.stderr)
        self.assertIn("resident addition", result.stderr)
        self.assertIn("house-memory remember", result.stderr)
        self.assertIn("graph pending", result.stderr)

    def prepare_review(self):
        self.install()
        name = installer.SCRIPTS[0]
        self.stock(b"stock v2\n")
        (self.live / name).write_bytes(b"stock v2 + resident edits\n")
        self.install()
        return name

    def ack(self, name):
        return installer.acknowledge(self.source, self.live, name,
            installer.digest((self.source / name).read_bytes()),
            installer.digest((self.live / name).read_bytes()))

    def test_ack_advances_ancestor_and_clears_notice_across_reboots(self):
        name = self.prepare_review()
        before = (self.live / name).read_bytes()
        self.assertEqual([], self.ack(name))
        self.assertEqual(b"stock v2\n", (self.live / ".house-stock" / name).read_bytes())
        for _ in range(2):
            self.assertEqual([], self.install())
            self.assertEqual(before, (self.live / name).read_bytes())
            self.assertFalse((self.live / (name + ".upstream")).exists())
            self.assertFalse((self.live / "HOUSE-HOOK-UPDATES.md").exists())
        self.stock(b"stock v3\n")
        self.assertEqual([name], self.install())
        self.assertEqual(before, (self.live / name).read_bytes())
        self.assertEqual(b"stock v2\n", (self.live / ".house-stock" / name).read_bytes())
        self.assertEqual(b"stock v3\n", (self.live / (name + ".upstream")).read_bytes())

    def test_active_edit_after_ack_requires_fresh_review(self):
        name = self.prepare_review()
        self.ack(name)
        (self.live / name).write_bytes(b"changed again\n")
        self.assertEqual([name], self.install())

    def test_stale_ack_rejected_without_changing_ancestor_or_receipt(self):
        for changed in ("stock", "active", "staged"):
            with self.subTest(changed=changed):
                name = self.prepare_review()
                upstream_hash = installer.digest((self.source / name).read_bytes())
                active_hash = installer.digest((self.live / name).read_bytes())
                target = {"stock": self.source / name, "active": self.live / name,
                          "staged": self.live / (name + ".upstream")}[changed]
                target.write_bytes(b"changed after review\n")
                baseline = (self.live / ".house-stock" / name).read_bytes()
                with self.assertRaises(ValueError):
                    installer.acknowledge(self.source, self.live, name, upstream_hash, active_hash)
                self.assertEqual(baseline, (self.live / ".house-stock" / name).read_bytes())
                self.assertFalse((self.live / ".house-stock" / (name + ".reviewed.json")).exists())

    def test_seeded_real_ancestor_is_respected_but_not_an_ack(self):
        name = installer.SCRIPTS[0]
        baseline = self.live / ".house-stock" / name
        baseline.parent.mkdir()
        baseline.write_bytes(b"stock v1\n")
        (self.live / name).write_bytes(b"stock v1 + resident edits\n")
        self.stock(b"stock v2\n")
        self.assertEqual([name], self.install())
        self.assertEqual(b"stock v1\n", baseline.read_bytes())
        self.assertEqual(b"stock v1 + resident edits\n", (self.live / name).read_bytes())

    def test_ack_does_not_clear_other_hook_notice(self):
        name = self.prepare_review()
        other = installer.SCRIPTS[1]
        (self.live / other).write_bytes(b"other resident customization\n")
        self.install()
        self.assertEqual([other], self.ack(name))
        notice = (self.live / "HOUSE-HOOK-UPDATES.md").read_text()
        self.assertNotIn(f"- `{name}`", notice)
        self.assertIn(f"- `{other}`", notice)

    def test_cli_ack_and_missing_hash_refusal(self):
        name = self.prepare_review()
        command = ["python3", str(RUNTIME / "install_memory_scripts.py"),
                   str(self.source), str(self.live), "--ack", name]
        refused = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(0, refused.returncode)
        result = subprocess.run(command + [
            "--upstream-sha256", installer.digest((self.source / name).read_bytes()),
            "--active-sha256", installer.digest((self.live / name).read_bytes())],
            capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.install())

    def test_image_and_entrypoint_wire_installer_before_hook_merge(self):
        dockerfile = (RUNTIME / "Dockerfile").read_text()
        self.assertIn("COPY memory_before_turn.py install_memory_hooks.py install_memory_scripts.py /usr/local/share/helixkit-agent/", dockerfile)
        entrypoint = (RUNTIME / "entrypoint.sh").read_text()
        self.assertLess(entrypoint.index("python3 /usr/local/share/helixkit-agent/install_memory_scripts.py"), entrypoint.index('install_hooks_json "$AGENT_REPO_PATH/.chaos/hooks.json"'))
        self.assertNotIn("cp /usr/local/share/helixkit-agent/stop_journal_reflex.py", entrypoint)
        self.assertNotIn("cp /usr/local/share/helixkit-agent/memory_before_turn.py", entrypoint)


if __name__ == "__main__":
    unittest.main()
