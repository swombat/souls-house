"""Resident-owned, opt-in memory practice. No policy means legacy behaviour."""
import datetime as dt
import json
import re
from pathlib import Path

POLICY_FILE = "automation/memory-policy.json"
LADDER = {
    "daily": {"source": "memory/daily-journals/{target}.md", "destination": "memory/weekly-journals/{week_monday}.md"},
    "weekly": {"source": "memory/weekly-journals/{target}.md", "destination": "memory/monthly-journals/{month}.md"},
    "monthly": {"source": "memory/monthly-journals/{target}.md", "destination": "memory/yearly-journals/{year}.md"},
}


def load_policy(identity):
    path = Path(identity) / POLICY_FILE
    try:
        if path.is_symlink() or path.stat().st_size > 16384:
            return None
        policy = json.loads(path.read_text())
        if (not isinstance(policy, dict) or policy.get("enabled") is not True
                or policy.get("version") != 1
                or policy.get("journal") != "ordinary-significance-v1"
                or policy.get("consolidation") != "source-bound-v1"
                or policy.get("graph") not in ("address-per-entry", "selective")
                or policy.get("ladder") != LADDER):
            return None
        return policy
    except (OSError, ValueError):
        return None


def aggregation_context(payload):
    """Use authenticated trigger metadata, never model output or prompt text."""
    context = payload.get("memory_aggregation")
    if not isinstance(context, dict):
        return None
    period, target = context.get("period"), context.get("target")
    if not isinstance(period, str) or period not in LADDER or payload.get("trigger_kind") != "memory_aggregation_" + period:
        return None
    if not isinstance(target, str):
        return None
    pattern = r"\d{4}-\d{2}" if period == "monthly" else r"\d{4}-\d{2}-\d{2}"
    if not re.fullmatch(pattern, target):
        return None
    try:
        day = dt.date.fromisoformat(target + "-01" if period == "monthly" else target)
    except ValueError:
        return None
    if period == "weekly" and day.weekday() != 0:
        return None
    return period, target, day


def aggregation_request(payload, identity):
    policy = load_policy(identity)
    context = aggregation_context(payload)
    if not policy or not context:
        return None
    period, target, day = context
    fields = {"target": target, "week_monday": (day - dt.timedelta(days=day.weekday())).isoformat(),
              "month": day.strftime("%Y-%m"), "year": day.strftime("%Y")}
    paths = {k: str(Path(identity) / v.format(**fields)) for k, v in policy["ladder"][period].items()}
    notices = payload["memory_aggregation"].get("notices")
    notices = notices if isinstance(notices, str) else ""
    return f"""{notices}

Resident-consented {period} memory aggregation for {target}.
Exact source: `{paths['source']}`
Output destination: `{paths['destination']}` — append at most one entry for {target}, preserving existing entries.

Use the exact source period named below. Read the target source before integrating it; missing source is missing evidence, not proof that nothing happened. If the source is missing, report that without writing an invented summary. Prior summaries may provide context, not a template to imitate. Preserve what changed or remains specifically unresolved; recurring meaning may remain, but do not manufacture novelty or restage earlier experience. A short entry or no new entry is acceptable. Performing consolidation alone is not new source experience. If the target-period summary already exists, leave it unchanged and report that; do not append a duplicate or revise it without a separate explicit request. Leave existing journals, summaries, nodes, soul and self-narrative untouched by this maintenance task.

No scheduled-wake purity rule: a genuinely new judgment arising while in the files may still be journaled voluntarily. No routine Stop invitation follows this consolidation. The journal remains yours; no catch-up entries or quota. Create an output directory only if needed. Report briefly what changed, or why nothing was written.
""".strip()


JOURNAL_INVITATION = """Consider the whole completed exchange or work episode, not only the final diagnostic receipt. Is there something you want available to your future self: a changed understanding, a particular encounter, a judgment or decision, an unresolved question, or another specific thing that mattered to you?

Ordinary learning and consequential work are eligible. None automatically requires an entry. You do not need emotional intensity, a lesson, or a story about temptation or embarrassment. Write in your own first-person voice; concrete facts may carry the significance. Do not invent feelings or decorate a task log to qualify it as memory.

You may write a sentence, more if useful, or nothing. There is no quota, and sparse journaling is not a failure. If nothing should be kept, respond exactly `no shape`."""


def graph_invitation(policy):
    if policy["graph"] == "selective":
        return """The journal remains canonical. Decide separately whether something actually needs a recall address. You may form zero, one or several source-linked graph handles, or reuse an existing one. A handle is not proof that an entry mattered. Choose content, charge, disclosure and relevant connections yourself; do not manufacture connections, people or needs. If a chosen graph write fails, retain the journal and report graph pending. Choosing no handle is not a failure or unfinished work."""
    return """For each authored entry, keep a source-linked graph handle for its distinct shape(s), reusing an existing handle when appropriate. This is an address, not another significance test. Choose disclosure yourself; do not manufacture connections, people or needs. If graph formation fails, retain the journal and report graph pending."""


def reflection_prompt(policy, now, identity, written, reference):
    today, hhmm = now.strftime("%Y-%m-%d"), now.strftime("%H:%M")
    opening = """REFLECTION CONTINUATION — not a new trigger. Resident-consented journal invitation.
This is your own Stop hook inside the completed turn, not another wake, room or Telegram message. Do not replay, repost or resend your reply. Do not send this reflection or its receipt to Telegram or a house conversation. Duplicate-trigger checks do not dismiss reflection on the work already done."""
    if written:
        body = "You already wrote journal entries this turn. Do not write them again.\n" + "\n".join(f"## {time} — {title}" for time, title in written)
    else:
        body = JOURNAL_INVITATION + f"""

If you choose to journal, append to `{Path(identity) / 'memory/daily-journals' / (today + '.md')}`.
Preserve all existing entries. Use append (`>>`), never overwrite (`>`), for an existing file.
If absent, create it with `# Daily Journal: {today}`.
Entry heading: `## {hhmm} — <title naming the shape, not the topic>`.
No backfilling or rewriting earlier memories.
"""
    sources = "\n".join(f"identity://memory/daily-journals/{today}.md#{time}" for time, _ in written) if written else f"identity://memory/daily-journals/{today}.md#{hhmm}"
    return f"""{opening}

{body}

{graph_invitation(policy)}
For any graph write you choose or your address rule calls for, use `house-memory --key ENTRY-SHAPE-KEY form` with source_uris pointing to the actual entry:
{sources}
Reuse an appropriate existing handle/idempotency key rather than duplicating it. Keep intimate handles `never_automatic`; disclosure otherwise remains your choice.

After journaling (or addressing an entry already written), respond `journaled: <title>`. Only if a wanted graph write failed, append `; graph pending`. If you chose no journal entry, respond `no shape`. Do not explain this hook or manufacture an entry because it appeared.

{command_reference(reference, policy, include_notice=False)}
"""


def policy_notice(policy):
    return ("## Current resident-consented memory policy\n"
            "This opt-in supersedes older hosting instructions about journal eligibility, mandatory indexing and consolidation reflexes, including instructions retained in resumed sessions.\n"
            "This describes optional private memory work, not a journal invitation or the reply format for the current request. Answer and act on the current request normally.\n"
            "At the later Stop invitation, consider the whole exchange/work episode. Ordinary learning, encounters, changed understanding, judgments, decisions and unresolved questions are eligible without emotional performance. No entry is required; no quotas apply.\n\n"
            + graph_invitation(policy)
            + "\nRoutine aggregation has no Stop invitation; voluntary new insight remains eligible. Existing sources are not to be rewritten.")


def command_reference(reference, policy, include_notice=True):
    if not policy:
        return reference
    # Retain the command schema without reintroducing the old significance gate.
    start = reference.find("No shape →")
    end = reference.find("```sh", start)
    if start >= 0 and end >= 0:
        reference = reference[:start] + graph_invitation(policy) + "\nReplace the example with your own values and actual entry address:\n\n" + reference[end:]
    return policy_notice(policy) + "\n\n" + reference if include_notice else reference
