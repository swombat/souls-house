"""soulshouse-commitment, offline: no credentials, server or network. In runtime CI discovery."""
import argparse
import datetime
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader("commitment_cli", str(Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-commitment"))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)

NOW = datetime.datetime(2026, 11, 2, 7, 30, 15, 999, tzinfo=datetime.timezone.utc)


def args(**overrides):
    base = dict(conversation=None, text="Check it", text_file=None, at=None, within="30m",
                source_message=None, new_conversation=False, room=None, room_id=None, summary=None)
    base.update(overrides)
    return argparse.Namespace(**base)


class CommitmentTests(unittest.TestCase):
    def test_in_is_relative_to_now_in_utc(self):
        self.assertEqual("2026-11-02T08:00:15Z", cli.due_at(within="30m", now=NOW))
        self.assertEqual("2026-11-03T07:30:15Z", cli.due_at(within="1d", now=NOW))
        self.assertEqual("2026-11-03T03:00:00+01:00", cli.due_at(at="2026-11-03T03:00:00+01:00"))

    def test_in_refuses_anything_else(self):
        for bad in ["30", "soon", "-5m", "1.5h"]:
            with self.assertRaises(ValueError):
                cli.due_at(within=bad, now=NOW)

    def test_ids_cannot_escape_the_endpoint(self):
        self.assertEqual("/api/v1/commitments/..%2Fagents", cli.commitment_path("../agents"))

    def test_add_defaults_to_the_running_conversation(self):
        payload = cli.build_add_payload(args(), {"SOULSHOUSE_RUNTIME_CHAT_ID": "JrBDwJ"})
        self.assertEqual("JrBDwJ", payload["conversation_id"])
        self.assertNotIn("destination", payload)

    def test_add_needs_a_conversation(self):
        with self.assertRaises(ValueError):
            cli.build_add_payload(args(), {})

    def test_new_conversation_carries_the_room(self):
        payload = cli.build_add_payload(args(conversation="c1", new_conversation=True, room="Ops"), {})
        self.assertEqual(("new_conversation", "Ops"), (payload["destination"], payload["room"]))

    def test_summary_is_sent_trimmed_and_only_when_given(self):
        payload = cli.build_add_payload(args(conversation="c1", summary="  Check the deploy receipt "), {})
        self.assertEqual("Check the deploy receipt", payload["summary"])
        self.assertNotIn("summary", cli.build_add_payload(args(conversation="c1"), {}))
        self.assertNotIn("summary", cli.build_add_payload(args(conversation="c1", summary="   "), {}))

    def test_room_without_new_conversation_is_refused(self):
        with self.assertRaises(ValueError):
            cli.build_add_payload(args(conversation="c1", room="Ops"), {})


if __name__ == "__main__":
    unittest.main()
