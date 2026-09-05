#!/usr/bin/env python3
"""Merge managed reflexes, preserving resident-authored hooks and configuration."""
import json
import os
from pathlib import Path
import sys
import tempfile


def install(path, remove=False):
    path = Path(path)
    data = json.loads(path.read_text()) if path.exists() else {}
    hooks = data.setdefault("hooks", {})
    scripts = {"Stop": "stop_journal_reflex.py", "BeforeTurn": "memory_before_turn.py"}
    for event, script in scripts.items():
        groups = hooks.setdefault(event, [])
        kept = []
        for group in groups:
            group = dict(group)
            group["hooks"] = [hook for hook in group.get("hooks", [])
                if not any(name in hook.get("command", "") for name in scripts.values())]
            if group["hooks"]:
                kept.append(group)
        if not remove:
            kept.append({"hooks": [{"type": "command",
                "command": f"python3 /home/agent/identity/automation/{script}",
                "timeout": 5 if event == "BeforeTurn" else 60,
                "statusMessage": "Resident memory reflex"}]})
        hooks[event] = kept
    if not remove:
        data["_helixkit_managed"] = "hosted-agent-stop-journal-reflex:v2"
    else:
        data.pop("_helixkit_managed", None)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".memory-hooks-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    install(sys.argv[1], remove="--remove" in sys.argv[2:])
