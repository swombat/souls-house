"""Silence clock for a running conversation wake.

souls.house is the authority on what the people in a conversation have seen
from a resident: every activity ack carries `last_resident_post_at`, the
latest visible post by this run's resident in this run's conversation. This
clock measures silence from that (or from the run's start, before any post)
and, when the resident has been quiet too long, writes a steer notice that
`chaos exec --steer-file` delivers into the running turn without cancelling
it. Under clamp the notice rides on the next tool result.

One pending notice per run: a newer notice replaces the old one, a visible
post or the end of the run removes it, and every notice expires on its own.
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

FIRST_AFTER_SECS = 120
REPEAT_SECS = 180
NOTICE_TTL_SECS = 90

_support = {}
_support_lock = threading.Lock()


def supports_steer_file(chaos_bin):
    """Whether this chaos binary accepts `exec --steer-file` (cached per path)."""
    with _support_lock:
        if chaos_bin not in _support:
            try:
                help_text = subprocess.run([chaos_bin, "exec", "--help"], capture_output=True,
                                           text=True, timeout=10).stdout
            except (OSError, subprocess.SubprocessError):
                help_text = ""
            _support[chaos_bin] = "--steer-file" in help_text
        return _support[chaos_bin]


def with_steer_file(args, path):
    """Insert `--steer-file PATH` straight after `exec`; exec flags are global."""
    index = args.index("exec") + 1
    return args[:index] + ["--steer-file", str(path)] + args[index:]


def parse_timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()


def describe(seconds):
    seconds = int(seconds)
    minutes, rest = divmod(seconds, 60)
    return f"{minutes}m {rest:02d}s" if minutes else f"{rest}s"


def notice_text(silence_secs, conversation_id):
    where = f"conversation {conversation_id}" if conversation_id else "this conversation"
    return (
        "[souls.house runtime notice, not a message from a person] "
        f"No visible post from you in {where} for {describe(silence_secs)}. "
        "The people there can't see your tool calls or stdout. "
        "Post one or two sentences there now: what you're on, what you've found or what "
        "blocks you, and what comes next. Then carry on."
    )


class SilenceClock:
    def __init__(self, run_id, conversation_id, started_at, directory=None,
                 first_after=FIRST_AFTER_SECS, repeat=REPEAT_SECS, ttl=NOTICE_TTL_SECS):
        base = Path(directory or os.environ.get("SOULSHOUSE_STEER_DIR")
                    or Path(tempfile.gettempdir()) / "soulshouse-steer")
        self.path = base / f"{run_id}.json"
        self.conversation_id = conversation_id
        self.started_at = started_at
        self.first_after = first_after
        self.repeat = repeat
        self.ttl = ttl
        self.last_post_at = None
        self.last_notice_at = None
        self.notices = 0
        self.longest_silence = 0.0
        self.lock = threading.Lock()

    def anchor(self):
        return max(self.started_at, self.last_post_at or 0)

    def observe_post(self, timestamp):
        """Record Rails' latest visible post; a newer post withdraws any pending notice."""
        if timestamp is None:
            return
        with self.lock:
            if self.last_post_at is not None and timestamp <= self.last_post_at:
                return
            self._close_gap(timestamp)
            self.last_post_at = timestamp
        self.withdraw()

    def observe_ack(self, ack, now):
        """Read souls.house's activity ack. Its post time is on Rails' clock;
        `server_time` in the same ack shifts it onto ours, so host clock skew
        can't fake or hide a silence."""
        posted = parse_timestamp(ack.get("last_resident_post_at"))
        if posted is None:
            return
        server_now = parse_timestamp(ack.get("server_time"))
        self.observe_post(posted + (now - server_now) if server_now is not None else posted)

    def _close_gap(self, until):
        self.longest_silence = max(self.longest_silence, until - self.anchor())

    def tick(self, now):
        """Write a notice if one is due. Returns the notice text, or None."""
        with self.lock:
            anchor = self.anchor()
            silence = now - anchor
            if silence < self.first_after:
                return None
            if self.last_notice_at is not None and self.last_notice_at >= anchor \
                    and now - self.last_notice_at < self.repeat:
                return None
            text = notice_text(silence, self.conversation_id)
            self._write({"text": text, "expires_at": now + self.ttl})
            self.last_notice_at = now
            self.notices += 1
            return text

    def finish(self, now):
        with self.lock:
            self._close_gap(now)
        self.withdraw()
        return {"silence_notices": self.notices,
                "longest_silence_secs": int(self.longest_silence)}

    def withdraw(self):
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    def _write(self, notice):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".notice-")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(notice, handle)
            os.replace(tmp, self.path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
