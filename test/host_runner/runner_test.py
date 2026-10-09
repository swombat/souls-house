import base64
import io
import json
import os
import stat
import sys
import tempfile
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))
sys.path.insert(0, HERE)

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

import make_vector  # noqa: E402
import souls_house_runner as runner  # noqa: E402


class FakeResponse:
    def __init__(self, status, payload):
        self.status = status
        self._body = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def opener_returning(status, payload, seen=None):
    def opener(request, timeout=None):
        if seen is not None:
            seen.append(request)
        if status >= 400:
            raise urllib.error.HTTPError(request.full_url, status, "err", {}, io.BytesIO(json.dumps(payload).encode()))
        return FakeResponse(status, payload)
    return opener


def failing_opener(request, timeout=None):
    raise urllib.error.URLError("connection refused")


CONFIG = {"rails_url": "https://house.example", "runner_id": "rnr_abc", "enrollment_token": "tok"}


class SignatureVectorTest(unittest.TestCase):
    def test_runner_still_produces_the_shared_vector(self):
        with open(make_vector.VECTOR_PATH) as handle:
            stored = json.load(handle)
        self.assertEqual(make_vector.build(), stored)

    def test_signature_covers_body_path_and_identity(self):
        key = Ed25519PrivateKey.from_private_bytes(make_vector.SEED)
        base = runner.signing_string("POST", "/p", b"{}", "rnr_a", 1, "n")
        for changed in (
            runner.signing_string("POST", "/p", b"{ }", "rnr_a", 1, "n"),
            runner.signing_string("POST", "/q", b"{}", "rnr_a", 1, "n"),
            runner.signing_string("POST", "/p", b"{}", "rnr_b", 1, "n"),
            runner.signing_string("POST", "/p", b"{}", "rnr_a", 2, "n"),
            runner.signing_string("POST", "/p", b"{}", "rnr_a", 1, "m"),
        ):
            self.assertNotEqual(base, changed)
        headers = runner.signed_headers(key, "post", "/p", b"{}", "rnr_a", timestamp=1, nonce="n")
        key.public_key().verify(base64.b64decode(headers["X-Runner-Signature"]), base.encode())


class KeyTest(unittest.TestCase):
    def test_key_is_generated_once_and_kept_private(self):
        with tempfile.TemporaryDirectory() as state:
            first = runner.load_or_create_key(state)
            second = runner.load_or_create_key(state)
            self.assertEqual(runner.public_key_b64(first), runner.public_key_b64(second))
            mode = stat.S_IMODE(os.stat(os.path.join(state, "runner_ed25519.key")).st_mode)
            self.assertEqual(mode, 0o600)


class EnrollTest(unittest.TestCase):
    def setUp(self):
        self.key = Ed25519PrivateKey.generate()

    def test_enrolled_and_already_enrolled_both_finish(self):
        for status in ("enrolled", "already_enrolled"):
            self.assertEqual(runner.enroll_once(CONFIG, self.key, {}, opener=opener_returning(200, {"status": status})), "enrolled")

    def test_not_yet_confirmed_and_transport_trouble_retry(self):
        self.assertEqual(runner.enroll_once(CONFIG, self.key, {}, opener=opener_returning(202, {"status": "pending"})), "pending")
        self.assertEqual(runner.enroll_once(CONFIG, self.key, {}, opener=opener_returning(503, {})), "pending")
        self.assertEqual(runner.enroll_once(CONFIG, self.key, {}, opener=failing_opener), "pending")
        self.assertEqual(runner.enroll_once(CONFIG, self.key, {}, opener=opener_returning(401, {"error": "clock_skew"})), "pending")

    def test_refusals_stop(self):
        for status, payload in ((401, {"error": "invalid_token"}), (409, {"error": "key_mismatch"}), (410, {"error": "expired"}), (422, {})):
            self.assertEqual(runner.enroll_once(CONFIG, self.key, {}, opener=opener_returning(status, payload)), "refused")

    def test_request_is_signed_and_sends_the_public_key(self):
        seen = []
        runner.enroll_once(CONFIG, self.key, {"provider_server_id": 7}, opener=opener_returning(202, {}, seen))
        request = seen[0]
        self.assertEqual(request.full_url, "https://house.example" + runner.ENROLL_PATH)
        body = json.loads(request.data)
        self.assertEqual(body["public_key"], runner.public_key_b64(self.key))
        headers = {k.lower(): v for k, v in request.header_items()}
        message = runner.signing_string(
            "POST", runner.ENROLL_PATH, request.data, "rnr_abc", headers["x-runner-timestamp"], headers["x-runner-nonce"]
        ).encode()
        self.key.public_key().verify(base64.b64decode(headers["x-runner-signature"]), message)


class MainLoopTest(unittest.TestCase):
    def run_main(self, outcomes):
        state = tempfile.mkdtemp()
        config_path = os.path.join(state, "config.json")
        with open(config_path, "w") as handle:
            json.dump(dict(CONFIG), handle)
        keys_seen = []

        def enroll(config, key, facts):
            keys_seen.append(runner.public_key_b64(key))
            return outcomes.pop(0)

        beats = []
        code = runner.main(
            config_path=config_path, state_dir=state, sleep=lambda s: None, enroll=enroll,
            heartbeat=lambda config, key, facts: beats.append(facts), facts=lambda image: {"provider_server_id": 7},
            max_heartbeats=2,
        )
        with open(config_path) as handle:
            final_config = json.load(handle)
        return code, keys_seen, beats, final_config, state

    def test_pending_then_enrolled_reuses_one_key_then_drops_the_token(self):
        code, keys, beats, config, state = self.run_main(["pending", "pending", "enrolled"])
        self.assertEqual(code, 0)
        self.assertEqual(len(set(keys)), 1)
        self.assertEqual(len(beats), 2)
        self.assertNotIn("enrollment_token", config)
        self.assertTrue(os.path.exists(os.path.join(state, "enrolled")))

    def test_refusal_stops_after_one_unanswered_recovery_heartbeat(self):
        code, _, beats, config, _ = self.run_main(["refused"])
        self.assertEqual(code, 3)
        self.assertEqual(len(beats), 1)
        self.assertIn("enrollment_token", config)


class OriginTest(unittest.TestCase):
    def test_only_a_bare_https_origin_is_accepted(self):
        self.assertEqual(runner.validate_origin("https://house.example/"), "https://house.example")
        self.assertEqual(runner.validate_origin("https://house.example:8443"), "https://house.example:8443")
        for bad in ("http://house.example", "https://u:p@house.example", "https://house.example/api",
                    "https://house.example?x=1", "https://house.example#f", "https://", "", None):
            with self.assertRaises(runner.BadOrigin, msg=repr(bad)):
                runner.validate_origin(bad)


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.state = tempfile.mkdtemp()
        self.config_path = os.path.join(self.state, "config.json")

    def write_config(self, **overrides):
        with open(self.config_path, "w") as handle:
            json.dump({**CONFIG, **overrides}, handle)

    def read_config(self):
        with open(self.config_path) as handle:
            return json.load(handle)

    def run_main(self, enroll=None, heartbeat=None):
        return runner.main(
            config_path=self.config_path, state_dir=self.state, sleep=lambda s: None,
            enroll=enroll or (lambda *a: self.fail("should not enroll")),
            heartbeat=heartbeat or (lambda *a: 200), facts=lambda image: {}, max_heartbeats=1,
        )

    def test_bad_origin_stops_before_any_request(self):
        self.write_config(rails_url="http://house.example")
        self.assertEqual(self.run_main(heartbeat=lambda *a: self.fail("should not send")), 4)

    def test_spent_token_left_by_a_crash_is_cleaned_up_at_start(self):
        self.write_config()
        open(os.path.join(self.state, "enrolled"), "w").close()
        self.assertEqual(self.run_main(), 0)
        self.assertNotIn("enrollment_token", self.read_config())

    def test_refused_enrollment_recovers_when_the_pinned_key_still_heartbeats(self):
        self.write_config()
        self.assertEqual(self.run_main(enroll=lambda *a: "refused", heartbeat=lambda *a: 200), 0)
        self.assertTrue(os.path.exists(os.path.join(self.state, "enrolled")))
        self.assertNotIn("enrollment_token", self.read_config())

    def test_refused_enrollment_without_a_working_key_needs_review(self):
        self.write_config()
        self.assertEqual(self.run_main(enroll=lambda *a: "refused", heartbeat=lambda *a: 401), 3)
        self.assertIn("enrollment_token", self.read_config())


class AllowlistTest(unittest.TestCase):
    def test_the_vocabulary_is_fixed(self):
        self.assertEqual(runner.ALLOWED_ACTIONS, {
            "report_facts", "heartbeat",
            "start_resident", "stop_resident", "submit_turn", "turn_status", "cancel_turn", "seed_home", "backup_resident", "provider_auth",
        })
        for action in ("shell", "start_container", "docker_run", "", "REPORT_FACTS"):
            with self.assertRaises(runner.RefusedAction):
                runner.require_allowed(action)

    def test_facts_use_injected_readers(self):
        calls = []
        facts = runner.collect_facts(
            runtime_image="ghcr.io/x@sha256:abc",
            server_id_reader=lambda: 4242,
            command_runner=lambda argv: calls.append(argv) or "27.0",
        )
        self.assertEqual(facts["provider_server_id"], 4242)
        self.assertEqual(facts["docker_version"], "27.0")
        self.assertTrue(all(argv[0] == "docker" and argv[1] in ("image", "version") for argv in calls))


if __name__ == "__main__":
    unittest.main()
