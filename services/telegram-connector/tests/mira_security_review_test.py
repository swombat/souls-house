"""Task-local security regressions; synthetic secrets only."""

import json
import os
import tempfile
import unittest

from connector import commands
from connector.store import Crypto, Store
from tests import test_process


class ReviewCommandTest(unittest.TestCase):
    def test_valid_signature_cannot_bind_a_different_body_or_path(self):
        now = 1000
        key = "synthetic-command-key-" * 3
        command_id = "b" * 32
        fields = dict(connection="svc_1", operation="logout",
                      command_id=command_id, issued_at=now)
        body = json.dumps(fields).encode()
        headers = {
            "X-Comms-Key-Id": "k1",
            "X-Comms-Command-Id": command_id,
            "X-Comms-Issued-At": str(now),
            "X-Comms-Command-Signature": commands.sign(
                key, "k1", "svc_1", "logout", command_id, now, body),
        }
        for ref, operation, raw, code in (
            ("svc_2", "logout", body, "bad_signature"),
            ("svc_1", "search", body, "bad_signature"),
            ("svc_1", "logout", body + b" ", "bad_signature"),
        ):
            with self.assertRaises(commands.Refused) as caught:
                commands.verify(keys={"k1": key}, headers=headers,
                                connection=ref, operation=operation, body=raw,
                                now=now, consume=lambda _: self.fail("nonce consumed"))
            self.assertEqual(code, caught.exception.code)

    def test_nonce_remains_consumed_after_store_reopen(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "store.sqlite3")
            first = Store(path, Crypto("synthetic-store-key-" * 3))
            self.assertTrue(first.consume_command_id("a" * 32, 1000, 180))
            first.db.close()
            second = Store(path, Crypto("synthetic-store-key-" * 3))
            self.assertFalse(second.consume_command_id("a" * 32, 1001, 180))
            second.db.close()


class ReviewProcessTest(test_process.ProcessTest):
    # Reuse the existing real subprocess/TLS harness without rerunning
    # unrelated account and durable-sync tests.
    test_connect_live_messages_and_a_sigkill_between_outbox_and_state = None
    test_two_step_password_never_reaches_the_log_or_the_store = None


if __name__ == "__main__":
    unittest.main()
