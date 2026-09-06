#!/usr/bin/env python3
"""Merge managed reflexes, preserving resident-authored hooks and configuration."""
import json
import os
from pathlib import Path
import sys
import tempfile


def install(path, remove=False):
    path = Path(path)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
            raise ValueError("Invalid hooks structure")
        for groups in data.get("hooks", {}).values():
            if not isinstance(groups, list):
                raise ValueError("Invalid hook groups")
            for group in groups:
                if not isinstance(group, dict) or not isinstance(group.get("hooks", []), list):
                    raise ValueError("Invalid hook group")
                if any(not isinstance(hook, dict) or not isinstance(hook.get("command", ""), str)
                       for hook in group.get("hooks", [])):
                    raise ValueError("Invalid hook command")
    except (ValueError, UnicodeError):
        # Preserve the exact resident-authored bytes without printing them.
        fd, backup = tempfile.mkstemp(prefix=path.name + ".invalid-", dir=path.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(path.read_bytes())
        print(f"Invalid memory hook configuration preserved at {backup}; rebuilding managed hooks", file=sys.stderr)
        data = {}
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
                "timeout": 7 if event == "BeforeTurn" else 60,
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
