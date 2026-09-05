#!/usr/bin/env python3
"""Managed hosted BeforeTurn reflex. No source text or queries are logged."""
import json
import subprocess
import sys


def input_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(input_text(item) for item in value)
    if isinstance(value, dict):
        return input_text(value.get("text") or value.get("content") or "")
    return ""


def main():
    try:
        event = json.loads(sys.stdin.read(65536))
        messages = event.get("input_messages") or []
        text = input_text(messages[-1] if messages else event.get("input") or event.get("prompt") or event.get("last_user_message") or "")
        # The trigger shim already supplies the fresh/resumed conversation preview.
        # The hook closes the loop for direct resident harness turns too.
        if "Recalled memory candidates — not current chat transcript" in text:
            return
        if not text.strip() or event.get("stop_hook_active"):
            return
        result = subprocess.run(
            [sys.executable, "/home/agent/memory_client.py", "--preview"],
            input=json.dumps({"enabled": True, "query": text[-2000:]}),
            text=True, capture_output=True, timeout=2.5)
        # Client stderr contains only its status line; don't forward arbitrary errors.
        import re
        status = re.search(r"mnemodyne_preview=(ok|empty|held|timeout|unavailable|http_[0-9]{3})\b", result.stderr)
        print(status.group(0) if status else "mnemodyne_preview=unavailable", file=sys.stderr)
        if result.returncode == 0 and len(result.stdout.encode()) <= 12000:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "BeforeTurn",
                "additionalContext": result.stdout.strip()}}))
    except subprocess.TimeoutExpired:
        print("mnemodyne_preview=timeout", file=sys.stderr)
    except Exception:
        print("mnemodyne_preview=unavailable", file=sys.stderr)


if __name__ == "__main__":
    main()
