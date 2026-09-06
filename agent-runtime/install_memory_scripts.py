#!/usr/bin/env python3
"""Update pristine house hooks; stage upstream changes beside resident edits."""
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


def install(source, destination):
    source, destination = Path(source), Path(destination)
    pending = []
    for name in SCRIPTS:
        live = destination / name
        baseline = destination / ".house-stock" / name
        staged = destination / (name + ".upstream")
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
            text += (f"last installed stock is `.house-stock/{name}`.\n" if known
                     else "previous stock baseline is unknown; no ancestor was invented.\n")
        text += ("\nCompare both your additions and upstream changes before rebasing. "
                 "Do not blindly restore an older backup or copy the staged file over your edits. "
                 "Staged files track the latest image; the last-installed baseline stays fixed "
                 "while edits are preserved. Keeping edits does not automatically incorporate new house features. "
                 "To return to automatic updates, deliberately replace the active file with the reviewed current "
                 "stock; the next boot will recognize it and record the baseline.\n")
        write(notice, text.encode())
    else:
        notice.unlink(missing_ok=True)
    return pending


if __name__ == "__main__":
    install(*sys.argv[1:])
