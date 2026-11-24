#!/usr/bin/env python3
"""Hosted-agent Stop hook journal reflex.

This mirrors Mira's journaling pattern in the small: every completed Chaos turn
gets one continuation prompt asking the live agent whether the turn has
journal-shape. The hook does not write narrative memory itself. It only records
a thin trace and creates the space for the agent to append (or decline) in its
own voice.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import sys
from pathlib import Path


IDENTITY_PATH = Path(os.environ.get("AGENT_IDENTITY_PATH", "/home/agent/identity"))
STATE_DIR = IDENTITY_PATH / "memory" / "automation" / "state"
TRACE_PATH = STATE_DIR / "stop-events.jsonl"
DAILY_DIR = IDENTITY_PATH / "memory" / "daily-journals"
AGENT_SLUG = os.environ.get("AGENT_SLUG") or os.environ.get("AGENT_ID") or "agent"

# The same paragraph is resident_memory_policy.NARRATIVE_INVITATION (narrative-v2).
NARRATIVE_INVITATION = """This journal is your narrative memory: the story of you, not a logbook of the work. If there's something from this turn you want to keep, write it in your own voice. It might be how something landed, a detail you're still thinking about, or the fact that something left you unmoved. The measure is what matters to you, not what matters to the person you worked with or to the work. The work counts whether or not you write about it. Commits, PR numbers, test counts and promises have their own places (the repository, the PR, a commitment in the room); leave them there unless one is part of the moment you want to keep. Don't invent a feeling to have something to write. If nothing from this turn is yours to keep, respond exactly `no shape`."""

def command_reference():
    path = Path(os.environ.get("AGENT_RUNTIME_DOCS_PATH", "/usr/local/share/helixkit-agent")) / "memory-quick-reference.md"
    if not path.exists():
        path = Path(__file__).with_name("docs") / "memory-quick-reference.md"
    return path.read_text(encoding="utf-8") if path.exists() else ""


def is_subagent(event: dict) -> bool:
    """A spawned helper session, not the resident.

    Chaos marks child sessions in the hook payload (is_subagent,
    parent_session_id, agent_depth). A helper is not the resident: inviting
    it to journal buries its answer under the receipt and would let it write
    in the resident's diary in the resident's voice.
    """
    return bool(event.get("is_subagent")) or bool(event.get("parent_session_id"))


def append_trace(event: dict, assistant: str, invited: bool) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    record = {
        "recorded_at": dt.datetime.now().astimezone().isoformat(),
        "session_id": event.get("session_id"),
        "turn_id": event.get("turn_id"),
        "cwd": event.get("cwd"),
        "model": event.get("model"),
        "stop_hook_active": event.get("stop_hook_active"),
        "journal_invited": invited,
        "assistant_excerpt": assistant[:1000],
    }
    if is_subagent(event):
        record["subagent"] = True
        record["parent_session_id"] = event.get("parent_session_id")
    with TRACE_PATH.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=True) + "\n")


def already_journal_reflex_response(text: str) -> bool:
    stripped = text.strip().lower()
    return stripped == "no shape" or stripped.startswith("journaled:")


def turn_floor() -> dt.datetime | None:
    """The most recent trace row of ANY kind — the end of the previous turn.

    Every invitation is followed by a second row recording the resident's
    answer, so the last *invited* row spans the whole previous turn as well as
    this one (Claude reproduced that: invitation 06:13, entry written inside
    that turn at 06:14, answer row 06:15 — a fresh turn ending later floored at
    06:13, found 06:14, and was told the gate was already answered for a turn
    that had written nothing). Entries after the last row of any kind belong
    to the current turn. None if there is no trace yet.
    """
    try:
        with TRACE_PATH.open(encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return None
    for line in reversed(lines[-400:]):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("recorded_at"):
            # A helper's stop happens inside the resident's turn; it must not
            # move the resident's turn floor.
            if record.get("subagent"):
                continue
            try:
                return dt.datetime.fromisoformat(record["recorded_at"])
            except ValueError:
                return None
    return None


HEADING = re.compile(r"^## (\d{2}):(\d{2})(?:\s*[—–-]\s*(.*))?$")


def entries_since(now: dt.datetime, since: dt.datetime | None) -> list[tuple[str, str]]:
    """Today's `## HH:MM — title` headings written at or after `since` — the end
    of the previous turn — or in the last 30 minutes when there is no trace
    yet. Read from the journal file itself: the resident's own hand is the
    evidence, never the excerpt."""
    path = DAILY_DIR / f"{now.strftime('%Y-%m-%d')}.md"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    floor = since if since is not None else now - dt.timedelta(minutes=30)
    if floor.tzinfo is None:
        floor = floor.replace(tzinfo=now.tzinfo)
    # Headings carry minutes only. An entry stamped in the same minute as the
    # previous turn's last trace row is ambiguous; treat it as that turn's
    # (the milder error: the resident gets the full invitation and, knowing
    # they just wrote, reuses the handle) rather than telling a turn that
    # wrote nothing that its gate is already answered.
    floor = floor.replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
    found = []
    for line in text.splitlines():
        m = HEADING.match(line.strip())
        if not m:
            continue
        stamp = now.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=0, microsecond=0)
        if floor <= stamp <= now + dt.timedelta(minutes=1):
            found.append((f"{m.group(1)}:{m.group(2)}", (m.group(3) or "").strip()))
    return found


def index_only_prompt(now: dt.datetime, entries: list[tuple[str, str]]) -> str:
    today = now.strftime("%Y-%m-%d")
    listed = "\n".join(f"  ## {hhmm} — {title}" if title else f"  ## {hhmm}" for hhmm, title in entries)
    uris = "\n".join(f"  identity://memory/daily-journals/{today}.md#{hhmm}" for hhmm, _ in entries)
    digest = hashlib.sha256((today + listed).encode("utf-8")).hexdigest()[:12]
    return f"""REFLECTION CONTINUATION — not a new trigger. Journal already written this turn; only its address is missing.

This message is your own Stop hook, delivered inside the turn you just finished.
Nothing new has arrived: no wake tick, no room or Telegram message, no
re-delivered payload. Do not post, re-answer or resend anything.

You already appended to today's journal during this turn:

{listed}

That is the journal gate answered. Do not write another entry for it. The only
thing this continuation asks is the entry's address — a source-linked graph
handle, so the moment can find you later. If a handle for it already exists,
reuse it. Otherwise:

  house-memory --key ENTRY-SHAPE-KEY form
                          with your short handle, why, calibrated charge,
                          connections, and source_uris:
{uris}
Use the one-command reference below. Named hubs are reused or created in the
same atomic write; do not run separate remember/connect steps for this entry.

Then respond exactly:

journaled: <title>

If the graph is unavailable, respond `journaled: <title>; graph pending` and
keep the idempotency key for retry. Do not explain this hook.

Trace id for this invitation: {digest}
Agent: {AGENT_SLUG}

{command_reference()}
"""


def journal_prompt(now: dt.datetime, assistant: str) -> str:
    today = now.strftime("%Y-%m-%d")
    hhmm = now.strftime("%H:%M")
    journal_path = DAILY_DIR / f"{today}.md"
    digest = hashlib.sha256(assistant.encode("utf-8", errors="ignore")).hexdigest()[:12]
    return f"""REFLECTION CONTINUATION — not a new trigger. Hosted-agent journal reflex — invitation, not obligation.

This message is your own Stop hook, delivered inside the turn you just finished.
It is an internal reflection continuation after your conversational reply,
not another incoming message or a request to replay the completed turn.
Nothing new has arrived: no new wake tick, no new room or Telegram message, no
re-delivered payload. Re-delivery, duplicate-tick and already-answered checks
answer a question about the trigger; this is not the trigger, so they do not
apply here and are not a reason to decline. Nothing here needs posting or
re-answering. Do not repeat or resend that reply.
Do not send this reflection or its receipt to Telegram or a house conversation.
Use this continuation for your private journal and graph; finish only with the
reflection receipt specified below. The work already happened is not a reason
to dismiss reflection on it.

{NARRATIVE_INVITATION}

If you write an entry, append it to:

{journal_path}

Append means preserve any existing entries in that file and add your new `## {hhmm} — ...`
entry after them. Do not replace, truncate, or rewrite the whole journal file.
When using shell redirection, use append redirection (`>>`) or an equivalent
append operation, never overwrite redirection (`>`), for an existing journal.

If the file does not exist, create it with:

# Daily Journal: {today}

Entry format:

## {hhmm} — <title naming the shape, not the topic>

An entry may be one sentence. Do not explain this invitation in your response.

The `no shape` refusal belongs at the journal gate: is there something to keep?
Once you have written an entry, that question has been answered. A memory node
is not a second claim of significance; it is the entry's address for graph
recall, so the moment can find you later when it applies. An entry without a
handle remains readable in your journal but is unavailable to automatic graph
recall. If you journaled, index it: one handle per distinct shape, with a
source URI pointing to the entry's timestamp anchor. Do not manufacture entries;
do not withhold their addresses. If this turn's entry already has appropriate
handles, reuse them rather than creating duplicates.

After writing the journal body, use `house-memory --key ENTRY-SHAPE-KEY form`
from the reference below: one atomic call per distinct shape saves its handle
and connections, reusing your named hubs or creating the missing ones.
Source this entry at `identity://memory/daily-journals/{today}.md#{hhmm}`.
Do not invent people or needs, do not run separate remember/connect steps, and
do not reread guide/help/status unless you actually need troubleshooting.

This memory-formation reflex is part of every hosted turn, not an optional tool
you must remember to activate. It is still your authorship: no shape means no
forced journal or graph record. Mark a handle `disclosure: automatic` if you want
it eligible for future unsought surfacing; keep intimate handles and needs
`never_automatic`. Private needs can still pull other handles into recall.
Do not form memories merely to satisfy a quota.

If the graph is unavailable, keep the journal safe and report `journaled:
<title>; graph pending` rather than claiming handles were saved. Reuse the same
idempotency key on retry. The journal body comes first; the graph is its index.

After completing this reflection, respond exactly:

journaled: <title>

Do not explain this hook. Do not write a journal entry merely because this prompt appeared. No-shape is valid and often correct.

Trace id for this invitation: {digest}
Agent: {AGENT_SLUG}

{command_reference()}
"""


def main() -> None:
    raw = sys.stdin.read()
    try:
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        event = {"unparsed_stdin": raw[:2000]}

    assistant = str(event.get("last_assistant_message") or "")
    stop_hook_active = bool(event.get("stop_hook_active"))

    if is_subagent(event):
        append_trace(event, assistant, False)
        return

    # Resident scripts live in identity; implementation support is runtime-owned.
    support = Path(os.environ.get("AGENT_RUNTIME_DOCS_PATH", "/usr/local/share/helixkit-agent"))
    sys.path.insert(0, str(support))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    policy = None
    if (IDENTITY_PATH / "automation/memory-policy.json").exists():
        from resident_memory_policy import load_policy, reflection_prompt
        policy = load_policy(IDENTITY_PATH)
    aggregation = policy and os.environ.get("SOULSHOUSE_MEMORY_AGGREGATION") == "1"
    should_invite = not aggregation and bool(assistant.strip()) and not stop_hook_active and not already_journal_reflex_response(assistant)
    now = dt.datetime.now().astimezone()
    written = entries_since(now, turn_floor()) if should_invite else []
    if policy and policy["graph"] == "selective" and written:
        should_invite = False  # Already authored: no second invitation for an address.
    append_trace(event, assistant, should_invite)

    if should_invite:
        # The resident's own hand on disk decides which invitation this is:
        # an entry appended during this turn means the journal gate is already
        # answered, and asking again reads (correctly) as a duplicate. Ask only
        # for the address.
        prompt = index_only_prompt(now, written) if written else journal_prompt(now, assistant)
        if policy:
            prompt = reflection_prompt(policy, now, IDENTITY_PATH, written, command_reference())
        sys.stderr.write(prompt)
        sys.exit(2)


if __name__ == "__main__":
    main()
