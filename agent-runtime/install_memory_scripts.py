#!/usr/bin/env python3
"""Update pristine house hooks; stage upstream changes beside resident edits."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

SCRIPTS = ("stop_journal_reflex.py", "memory_before_turn.py")


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".house-hook-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def digest(content):
    return hashlib.sha256(content).hexdigest()


def reviewed_pair(path, current, incoming):
    try:
        receipt = json.loads(path.read_text())
        return (current is not None and isinstance(receipt, dict) and
                receipt.get("active_sha256") == digest(current) and
                receipt.get("upstream_sha256") == digest(incoming))
    except (OSError, ValueError, UnicodeError):
        return False


def acknowledge(source, destination, name, upstream_sha256, active_sha256):
    """Record a resident's review, not a claim that code was merged correctly."""
    if name not in SCRIPTS:
        raise ValueError("Unknown memory hook")
    source, destination = Path(source), Path(destination)
    live = destination / name
    staged = destination / (name + ".upstream")
    incoming = (source / name).read_bytes()
    current = live.read_bytes()
    # A stale review must not acknowledge newer stock or a subsequently edited
    # active script. Validate everything before writing any state.
    if digest(incoming) != upstream_sha256 or staged.read_bytes() != incoming:
        raise ValueError("Stock changed since review; no acknowledgment recorded")
    if digest(current) != active_sha256:
        raise ValueError("Active hook changed since review; no acknowledgment recorded")
    baseline = destination / ".house-stock" / name
    write(baseline, incoming)
    write(baseline.with_name(name + ".reviewed.json"), json.dumps({
        "upstream_sha256": upstream_sha256, "active_sha256": active_sha256
    }).encode())
    return install(source, destination)


def install(source, destination):
    source, destination = Path(source), Path(destination)
    pending = []
    for name in SCRIPTS:
        live = destination / name
        baseline = destination / ".house-stock" / name
        staged = destination / (name + ".upstream")
        receipt = baseline.with_name(name + ".reviewed.json")
        incoming = (source / name).read_bytes()
        # A resident symlink is not a platform-owned file, even if its target
        # happens to contain stock bytes. Never replace it or follow it to write.
        current = live.read_bytes() if live.is_file() else None
        previous = baseline.read_bytes() if baseline.is_file() else None
        if not live.is_symlink() and (
            not live.exists() or current == incoming or
            (previous is not None and current == previous)
        ):
            # Live first: interruption before baseline writes is conservative on
            # the next boot (unknown/modified), never permission to overwrite.
            if current != incoming:
                write(live, incoming, 0o755)
            write(baseline, incoming)
            staged.unlink(missing_ok=True)
            receipt.unlink(missing_ok=True)
        elif previous == incoming and reviewed_pair(receipt, current, incoming):
            # The resident explicitly reviewed this exact stock/active pair.
            # Keep their custom implementation, and don't repeat a cleared notice.
            staged.unlink(missing_ok=True)
        else:
            write(staged, incoming)
            pending.append(name)
            print(f"Preserved resident hook {live}; stock update staged at {staged}", file=sys.stderr)
    notice = destination / "HOUSE-HOOK-UPDATES.md"
    if pending:
        text = "# Pending house hook updates\n\n"
        text += "Your active hooks were preserved. No second hook was installed.\n\n"
        for name in pending:
            known = (destination / ".house-stock" / name).is_file()
            text += f"- `{name}`: incoming stock is `{name}.upstream`; "
            text += (f"last installed or explicitly reviewed stock is `.house-stock/{name}`.\n" if known
                     else "previous stock baseline is unknown; no ancestor was invented.\n")
        text += ("\nCompare both your additions and upstream changes before rebasing. "
                 "Do not blindly restore an older backup or copy the staged file over your edits. "
                 "Staged files track the latest image; the last-installed baseline stays fixed "
                 "until explicitly acknowledged. Keeping edits does not automatically incorporate new house features. "
                 "To return to automatic updates, deliberately replace the active file with the reviewed current "
                 "stock; the next boot will recognize it and record the baseline. "
                 "After reviewing/rebasing while keeping customizations, use install_memory_scripts.py "
                 "with --ack SCRIPT --upstream-sha256 SHA --active-sha256 SHA to advance the baseline "
                 "and clear only that exact reviewed pair. See house-memory guide for the command.\n")
        write(notice, text.encode())
    else:
        notice.unlink(missing_ok=True)
    return pending


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument("--ack", choices=SCRIPTS)
    parser.add_argument("--upstream-sha256")
    parser.add_argument("--active-sha256")
    args = parser.parse_args()
    if args.ack:
        if not args.upstream_sha256 or not args.active_sha256:
            parser.error("--ack requires both reviewed SHA-256 hashes")
        try:
            acknowledge(args.source, args.destination, args.ack,
                        args.upstream_sha256, args.active_sha256)
        except (OSError, ValueError):
            # No hook contents or hashes need to escape through diagnostics.
            parser.exit(1, "Acknowledgment did not complete: missing files, changed review pair, or I/O failure; recheck state before retrying.\n")
    else:
        if args.upstream_sha256 or args.active_sha256:
            parser.error("review hashes require --ack")
        install(args.source, args.destination)
