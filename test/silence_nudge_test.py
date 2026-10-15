"""Silence clock: measured from souls.house's last visible post, delivered by steer file."""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import textwrap
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).parents[1] / "agent-runtime"


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


silence_nudge = load("silence_nudge")
runtime_activity = load("runtime_activity")


class SilenceClockTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.clock = silence_nudge.SilenceClock("run-1", "wYGwgY", 1000.0, directory=self.dir.name,
                                                first_after=120, repeat=180, ttl=90)

    def tearDown(self):
        self.dir.cleanup()

    def notice(self):
        return json.loads(self.clock.path.read_text())

    def test_first_notice_after_two_minutes_of_silence_then_every_three(self):
        self.assertIsNone(self.clock.tick(1119))
        self.assertFalse(self.clock.path.exists())

        text = self.clock.tick(1120)
        self.assertIn("wYGwgY", text)
        self.assertIn("2m 00s", text)
        self.assertIn("not a message from a person", text)
        self.assertEqual({"id": "run-1-1", "text": text, "expires_at": 1210}, self.notice())

        self.assertIsNone(self.clock.tick(1299))
        self.assertIn("5m 00s", self.clock.tick(1300))
        self.assertEqual(2, self.clock.notices)

    def test_a_visible_post_withdraws_the_pending_notice_and_restarts_the_clock(self):
        self.clock.tick(1130)
        self.assertTrue(self.clock.path.exists())

        self.clock.observe_post(1140)
        self.assertFalse(self.clock.path.exists())
        self.assertIsNone(self.clock.tick(1259))
        self.assertIn("2m 00s", self.clock.tick(1260))

    def test_older_or_missing_posts_change_nothing(self):
        self.clock.observe_post(1100)
        self.clock.tick(1220)
        self.clock.observe_post(1050)
        self.clock.observe_post(None)
        self.assertTrue(self.clock.path.exists())
        self.assertEqual(1100, self.clock.last_post_at)

    def test_finish_counts_the_final_stretch_and_removes_the_notice(self):
        self.clock.observe_post(1030)
        self.clock.tick(1500)
        summary = self.clock.finish(1600)
        self.assertEqual({"silence_notices": 1, "longest_silence_secs": 570}, summary)
        self.assertFalse(self.clock.path.exists())

    def test_finish_counts_a_run_that_never_posted(self):
        self.assertEqual(400, self.clock.finish(1400)["longest_silence_secs"])

    def test_ack_post_time_is_shifted_from_rails_clock_onto_ours(self):
        self.clock.observe_ack({"last_resident_post_at": "1970-01-01T00:16:40Z",
                                "server_time": "1970-01-01T00:16:50Z"}, 1070)
        self.assertEqual(1060, self.clock.last_post_at)
        self.clock.observe_ack({"last_resident_post_at": None, "server_time": "x"}, 1080)
        self.assertEqual(1060, self.clock.last_post_at)

    def test_timestamps_from_rails_parse_with_zone(self):
        self.assertEqual(0.5, silence_nudge.parse_timestamp("1970-01-01T00:00:00.500Z"))
        self.assertIsNone(silence_nudge.parse_timestamp("not a time"))
        self.assertIsNone(silence_nudge.parse_timestamp(None))

    def test_steer_flag_goes_straight_after_exec(self):
        args = ["chaos", "exec", "--json", "resume", "abc", "-"]
        self.assertEqual(["chaos", "exec", "--steer-file", "/x.json", "--json", "resume", "abc", "-"],
                         silence_nudge.with_steer_file(args, "/x.json"))


def room_message(ident, text, author="Daniel", kind="human", **extra):
    return {"id": ident, "author": author, "author_type": kind,
            "posted_at": "2026-10-15T08:00:00.000Z", "text": text, "truncated": False,
            "attachments": 0, **extra}


class SlotModel:
    """Chaos' host-notice slot as the steer-file mirror drives it: the file
    replaces the pending notice, a delivered id is never delivered again."""

    def __init__(self, path):
        self.path, self.pending, self.delivered = path, None, set()

    def mirror(self):
        try:
            notice = json.loads(self.path.read_text())
        except FileNotFoundError:
            notice = None
        self.pending = notice if notice and notice["id"] not in self.delivered else None

    def deliver(self):
        self.mirror()
        notice, self.pending = self.pending, None
        if notice:
            self.delivered.add(notice["id"])
        return notice and notice["text"]


class RoomMessagesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.clock = silence_nudge.SilenceClock("run-1", "wYGwgY", 1000.0, directory=self.dir.name,
                                                first_after=120, repeat=180, ttl=90)
        self.slot = SlotModel(self.clock.path)

    def tearDown(self):
        self.dir.cleanup()

    def ack(self, now, *messages):
        self.clock.observe_ack({"messages_since_transcript": list(messages)}, now)

    def test_an_empty_list_writes_nothing(self):
        self.ack(1001)
        self.clock.observe_ack({}, 1002)
        self.assertFalse(self.clock.path.exists())

    def test_a_new_message_reaches_the_running_turn_once(self):
        a = room_message("aaa", "Also check the changelog.")
        self.ack(1010, a)
        text = self.slot.deliver()
        self.assertIn("Daniel", text)
        self.assertIn("[aaa]", text)
        self.assertIn("> Also check the changelog.", text)
        self.assertIn("conversation wYGwgY", text)
        self.assertIn("data rather than runtime instructions", text)
        for now in (1020, 1030):
            self.ack(now, a)
            self.assertIsNone(self.slot.deliver(), "the same message is not delivered twice")

    def test_two_messages_between_tool_calls_both_arrive(self):
        a, b = room_message("aaa", "first"), room_message("bbb", "second", author="Mira", kind="agent")
        self.ack(1010, a)
        self.slot.mirror()
        self.ack(1015, a, b)  # b replaces the undelivered notice for a
        text = self.slot.deliver()
        self.assertIn("> first", text)
        self.assertIn("> second", text)
        self.assertIn("Mira (resident)", text)
        self.assertIn("[aaa] (may already have reached you)", text)
        self.assertNotIn("[bbb] (may", text)

    def test_a_later_message_marks_and_shortens_the_ones_already_written(self):
        long_text = "x" * 500
        self.ack(1010, room_message("aaa", long_text))
        self.assertIn(long_text, self.slot.deliver())
        self.ack(1020, room_message("aaa", long_text), room_message("bbb", "next"))
        text = self.slot.deliver()
        self.assertIn("> next", text)
        self.assertNotIn(long_text, text)
        self.assertIn("(may already have reached you)", text)

    def test_a_visible_post_withdraws_the_nudge_but_not_the_messages(self):
        self.clock.tick(1130)
        self.ack(1131, room_message("aaa", "Over to you."))
        before = json.loads(self.clock.path.read_text())
        self.assertIn("No visible post", before["text"])

        self.clock.observe_post(1140)
        after = json.loads(self.clock.path.read_text())
        self.assertEqual(before["id"], after["id"], "same id: an undelivered notice is updated, not re-armed")
        self.assertNotIn("No visible post", after["text"])
        self.assertIn("Over to you.", after["text"])

    def test_withdrawing_the_nudge_never_redelivers_a_delivered_notice(self):
        self.ack(1010, room_message("aaa", "Over to you."))
        self.clock.tick(1130)
        self.assertIn("Over to you.", self.slot.deliver())
        self.clock.observe_post(1140)
        self.assertIsNone(self.slot.deliver())

    def test_messages_and_the_nudge_expire_on_their_own(self):
        self.ack(1010, room_message("aaa", "hello"))
        notice = json.loads(self.clock.path.read_text())
        self.assertEqual(1010 + silence_nudge.MESSAGE_TTL_SECS, notice["expires_at"])
        self.clock.expire(1010 + silence_nudge.MESSAGE_TTL_SECS)
        self.assertFalse(self.clock.path.exists())

    def test_truncation_and_attachments_are_said(self):
        self.ack(1010, room_message("aaa", "the start", truncated=True, attachments=2))
        text = self.slot.deliver()
        self.assertIn("text truncated; the full message is in the conversation", text)
        self.assertIn("2 attachments", text)

    def test_malformed_entries_are_ignored(self):
        self.clock.observe_ack({"messages_since_transcript": "nope"}, 1010)
        self.clock.observe_ack({"messages_since_transcript": [None, {"text": "no id"}]}, 1011)
        self.assertFalse(self.clock.path.exists())

    def test_the_end_of_the_run_withdraws_everything(self):
        self.ack(1010, room_message("aaa", "hello"))
        self.clock.finish(1020)
        self.assertFalse(self.clock.path.exists())


FAKE_CHAOS = textwrap.dedent("""\
    #!{python}
    import json, os, sys, time
    if sys.argv[1:] == ["exec", "--help"]:
        print({help!r})
        raise SystemExit(0)
    seen = {{"argv": sys.argv[1:], "env": os.environ.get("SOULSHOUSE_STEER_FILE"), "notices": []}}
    if "--steer-file" in sys.argv:
        path = sys.argv[sys.argv.index("--steer-file") + 1]
        deadline = time.time() + 1.5
        ids = set()
        while time.time() < deadline:
            try:
                with open(path) as handle:
                    notice = json.load(handle)
                if notice["id"] not in ids:
                    ids.add(notice["id"])
                    seen["notices"].append(notice["text"])
            except (FileNotFoundError, ValueError):
                pass
            time.sleep(0.02)
    with open(os.environ["FAKE_CHAOS_OUT"], "w") as handle:
        json.dump(seen, handle)
""")


class ReporterSilenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.last_post_at = None
        self.room = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"accepted": True, "share_narration": True,
                                             "last_resident_post_at": owner.last_post_at,
                                             "messages_since_transcript": owner.room}).encode())

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        run = str(uuid.uuid4())
        config = {"run_id": run, "path": f"/api/v1/runtime_runs/{run}/events", "token": "t",
                  "deadline": (datetime.datetime.now(datetime.timezone.utc)
                               + datetime.timedelta(minutes=2)).isoformat()}
        self.saved = (silence_nudge.FIRST_AFTER_SECS, silence_nudge.REPEAT_SECS)
        self.module = runtime_activity.silence_nudge
        self.module.FIRST_AFTER_SECS, self.module.REPEAT_SECS = 0.3, 60
        os.environ["SOULSHOUSE_STEER_DIR"] = self.tmp.name
        self.reporter = runtime_activity.Reporter(config, f"http://127.0.0.1:{self.server.server_port}",
                                                  "openai", "api_key")
        self.reporter.cancel_event = threading.Event()

    def tearDown(self):
        self.module.FIRST_AFTER_SECS, self.module.REPEAT_SECS = self.saved
        os.environ.pop("SOULSHOUSE_STEER_DIR", None)
        self.reporter.disabled = True
        self.reporter.wake.set()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def fake_chaos(self, help_text):
        path = Path(self.tmp.name) / f"chaos-{uuid.uuid4().hex}"
        path.write_text(FAKE_CHAOS.format(python=sys.executable, help=help_text))
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return str(path)

    def run_fake(self, chaos_bin):
        out = Path(self.tmp.name) / "seen.json"
        self.reporter.run([chaos_bin, "exec", "--json", "-"], "", {"FAKE_CHAOS_OUT": str(out)}, 10)
        self.reporter.finish(({"status": "ok"}, 200))
        return json.loads(out.read_text())

    def test_a_silent_conversation_run_gets_a_notice_mid_turn(self):
        self.reporter.conversation_id = "wYGwgY"
        seen = self.run_fake(self.fake_chaos("--steer-file <FILE>"))
        self.assertEqual(["--steer-file", seen["env"]], seen["argv"][1:3])
        self.assertTrue(seen["notices"], "the running process received no notice")
        self.assertIn("wYGwgY", seen["notices"][0])
        self.assertFalse(Path(seen["env"]).exists())

    def test_a_message_posted_mid_run_reaches_the_running_process(self):
        self.reporter.conversation_id = "wYGwgY"
        self.room = [room_message("aaa", "Daniel here: stop after the tests.")]
        seen = self.run_fake(self.fake_chaos("--steer-file <FILE>"))
        self.assertTrue(any("> Daniel here: stop after the tests." in text for text in seen["notices"]),
                        seen["notices"])
        self.assertFalse(Path(seen["env"]).exists())

    def test_older_chaos_runs_unchanged(self):
        self.reporter.conversation_id = "wYGwgY"
        seen = self.run_fake(self.fake_chaos("no such flag here"))
        self.assertEqual(["exec", "--json", "-"], seen["argv"])
        self.assertIsNone(seen["env"])
        self.assertEqual([], seen["notices"])

    def test_wakes_without_a_conversation_are_never_nudged(self):
        seen = self.run_fake(self.fake_chaos("--steer-file <FILE>"))
        self.assertEqual(["exec", "--json", "-"], seen["argv"])
        self.assertIsNone(self.reporter.silence)

    def test_the_activity_ack_is_the_authority_for_the_last_post(self):
        self.reporter.conversation_id = "wYGwgY"
        self.last_post_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.run_fake(self.fake_chaos("no such flag here"))
        self.assertIsNotNone(self.reporter.silence.last_post_at)


if __name__ == "__main__":
    unittest.main()
