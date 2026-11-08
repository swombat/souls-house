"""Cron wrapper contract tests; fake Docker/notifier, no production or network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class StonesTlsRenewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / "config"
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        for path in (self.config / "stones-tls", self.state, self.bin):
            path.mkdir(parents=True)
        (self.config / "settings.json").write_text('{"tools_image":"trusted-tools:test"}')
        (self.config / "stones-tls/porkbun.env").write_text("PRIVATE=fake-secret\n")
        self.log = self.root / "calls.jsonl"
        self.notices = self.root / "notices.jsonl"
        self.executable(self.bin / "docker", """#!/usr/bin/python3
import json, os, sys
with open(os.environ["CALLS"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")
if "--cron" in sys.argv:
    print("NEVER-LOG-SECRET")
    print("NEVER-LOG-SECRET", file=sys.stderr)
    sys.exit(int(os.environ.get("RENEW_FAIL", "0")))
if "prepare" in sys.argv:
    print("NEVER-LOG-SECRET")
    sys.exit(int(os.environ.get("PREPARE_FAIL", "0")))
if "install" in sys.argv:
    print(os.environ.get("RESULT", "installed"))
    print("NEVER-LOG-SECRET", file=sys.stderr)
    sys.exit(int(os.environ.get("INSTALL_FAIL", "0")))
print("NEVER-LOG-SECRET")
sys.exit(int(os.environ.get("CHECK_FAIL", "0")))
""")
        notifier = self.bin / "notifier"
        self.executable(notifier, """#!/usr/bin/python3
import json, os, sys
with open(os.environ["NOTICES"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")
print("NEVER-LOG-SECRET", file=sys.stderr)
sys.exit(int(os.environ.get("NOTIFY_FAIL", "0")))
""")
        (self.config / "stones-tls/notify-command").write_text(str(notifier))
        source = (Path(__file__).parents[1] / "ops/deploy/stones-tls-renew").read_text()
        source = source.replace("/etc/house-deploy", str(self.config))
        source = source.replace("/var/lib/house-deploy", str(self.state))
        source = source.replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin",
                                f"export PATH={self.bin}:/usr/sbin:/usr/bin:/sbin:/bin")
        # Exercise wrapper in unprivileged CI as well; the real script retains
        # its root gate and tests do not invoke any host privileged commands.
        source = source.replace("[[ $(id -u) = 0 ]] || exit 1", ": # test-only root gate")
        self.wrapper = self.root / "renew"
        self.executable(self.wrapper, source)

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o700)

    def run_wrapper(self, **extra):
        env = dict(os.environ, CALLS=str(self.log), NOTICES=str(self.notices), **extra)
        result = subprocess.run([str(self.wrapper)], env=env, text=True, capture_output=True)
        self.assertNotIn("NEVER-LOG-SECRET", result.stdout + result.stderr)
        if self.notices.exists():
            self.assertNotIn("NEVER-LOG-SECRET", self.notices.read_text())
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def subjects(self):
        return [json.loads(line)[0] for line in self.notices.read_text().splitlines()] if self.notices.exists() else []

    def test_changed_notifies_and_never_deploys(self):
        result = self.run_wrapper()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("installed; manual Deploy Rails required", result.stdout)
        self.assertEqual(["Stone TLS: renewal READY - approve Deploy Rails"], self.subjects())
        calls = self.calls()
        self.assertEqual(4, len(calls))
        self.assertIn("--cron", calls[0])
        self.assertIn("AUTO_UPGRADE=0", " ".join(calls[0]))
        self.assertIn("--config-home /acme.sh", " ".join(calls[0]))
        self.assertNotIn("--home /acme.sh", " ".join(calls[0]))
        self.assertNotIn("--env-file", calls[0])
        self.assertIn("prepare", calls[1])
        self.assertTrue(any("*.soulstones.fyi_ecc/fullchain.cer" in arg for arg in calls[1]))
        self.assertIn("install", calls[2])
        self.assertIn("check", calls[3])
        for call in calls:
            self.assertNotIn("deploy", call)
            self.assertNotIn("restart", call)
            self.assertNotIn("/var/run/docker.sock", " ".join(call))

    def test_unchanged_is_observable_without_release_notice(self):
        result = self.run_wrapper(RESULT="unchanged")
        self.assertEqual(0, result.returncode)
        self.assertIn("unchanged", result.stdout)
        self.assertEqual([], self.subjects())

    def test_acme_failure_still_installs_checks_and_alerts(self):
        result = self.run_wrapper(RENEW_FAIL="1", RESULT="unchanged")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(4, len(self.calls()))
        self.assertIn("Stone TLS: ACME renewal FAILED", self.subjects())

    def test_pending_or_expiring_live_certificate_alerts(self):
        result = self.run_wrapper(CHECK_FAIL="1")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Stone TLS: live certificate/expiry CHECK FAILED", self.subjects())

    def test_install_failure_does_not_claim_ready(self):
        result = self.run_wrapper(INSTALL_FAIL="1")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(["Stone TLS: renewal/monitor FAILED"], self.subjects())

    def test_prepare_failure_stops_before_install_and_notifies(self):
        result = self.run_wrapper(PREPARE_FAIL="1")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(2, len(self.calls()))
        self.assertEqual(["Stone TLS: renewal/monitor FAILED"], self.subjects())

    def test_notification_failure_is_nonzero_but_installed_status_survives(self):
        result = self.run_wrapper(NOTIFY_FAIL="1")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("installed; manual Deploy Rails required", result.stdout)

    def test_requires_explicit_notifier_no_default_email(self):
        (self.config / "stones-tls/notify-command").write_text("not a command")
        result = self.run_wrapper()
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
