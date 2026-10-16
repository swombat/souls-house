"""Fail-open worker boundary for invocation-local discovery."""

import json
import logging
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time
import tempfile
from datetime import datetime, timezone

MAX_OUTPUT = 16_384
MAX_NOTICE = 4096
WORKER_SECONDS = 3
RECEIPT_PATH = Path("/run/helixkit/capability-discovery-latest.json")
log = logging.getLogger(__name__)
FAILURE = "Capability discovery could not complete. No installation performed."
INVALID = "Invalid capability manifest. No installation performed."
DISCLAIMER = (
    "Discovery only; found does not establish working capability. "
    "No installation performed."
)


def _capture(command, timeout=WORKER_SECONDS):
    """Bound reads before allocation; kill/reap the direct worker on failure.

    Not an OS sandbox or descendant-process isolation. Popen itself is not
    interruptible here; the deadline governs capture after ordinary launch.
    """
    deadline = time.monotonic() + timeout
    with subprocess.Popen(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, shell=False,
    ) as process:
        try:
            output = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise ValueError("Worker deadline")
                    chunk = os.read(
                        process.stdout.fileno(),
                        min(4096, MAX_OUTPUT + 1 - len(output)),
                    )
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > MAX_OUTPUT:
                        raise ValueError("Worker output limit")
            remaining = deadline - time.monotonic()
            if remaining <= 0 or process.wait(timeout=remaining) != 0:
                raise ValueError("Worker failed")
            return bytes(output)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate protocol key")
        result[key] = value
    return result


def _result(raw):
    """Validate the complete protocol before rendering any worker strings."""
    data = json.loads(raw, object_pairs_hook=_unique_object)
    if not isinstance(data, dict) or set(data) != {"status", "items"}:
        raise ValueError("Protocol shape")
    status, items = data["status"], data["items"]
    if status not in ("ok", "absent", "invalid", "error"):
        raise ValueError("Protocol status")
    if not isinstance(items, list) or len(items) > 32:
        raise ValueError("Protocol items")
    if status != "ok":
        if items:
            raise ValueError("Protocol items")
        return (
            {"absent": "", "invalid": INVALID, "error": FAILURE}[status],
            {"absent": "absent", "invalid": "invalid", "error": "incomplete"}[status],
        )
    seen = set()
    grouped = {state: [] for state in ("missing", "unsupported", "error")}
    reviewed = {("apt", "ffmpeg"), ("pip", "numpy"), ("pip", "scipy")}
    for item in items:
        if not isinstance(item, dict) or set(item) != {"channel", "name", "state"}:
            raise ValueError("Protocol item")
        channel, name, state = item["channel"], item["name"], item["state"]
        if not isinstance(channel, str) or channel not in ("apt", "pip"):
            raise ValueError("Protocol channel")
        if (not isinstance(name, str) or len(name) > 128
                or not re.fullmatch(r"[a-z0-9][a-z0-9._+\-]*", name)):
            raise ValueError("Protocol name")
        if channel == "pip" and re.sub(r"[-_.]+", "-", name) != name:
            raise ValueError("Protocol normalization")
        if not isinstance(state, str) or state not in ("found", *grouped):
            raise ValueError("Protocol state")
        key = channel, name
        if key in seen or (key in reviewed) == (state == "unsupported"):
            raise ValueError("Protocol support")
        seen.add(key)
        if state != "found":
            grouped[state].append(f"{channel}:{name}")
    if not any(grouped.values()):
        return "", "all-found" if items else "empty"
    text = "Capability discovery: " + "; ".join(
        f"{state}: {', '.join(names)}" for state, names in grouped.items() if names
    )
    suffix = "\n" + DISCLAIMER
    # Protocol names are ASCII; slice before appending the explicit marker.
    if len((text + suffix).encode()) > MAX_NOTICE:
        marker = " [truncated]"
        text = text[:MAX_NOTICE - len(suffix) - len(marker)] + marker
    return text + suffix, "notice"


def render(raw):
    """Render a validated worker response without emitting a receipt."""
    return _result(raw)[0]


def _write_receipt(outcome):
    """Replace one local observation; not a trusted audit or durable archive."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=RECEIPT_PATH.parent,
            prefix=".capability-receipt-", delete=False,
        ) as stream:
            temporary = stream.name
            json.dump({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "outcome": outcome,
            }, stream)
            stream.write("\n")
        os.replace(temporary, RECEIPT_PATH)
    except Exception:
        # Missing directory, permissions, or disk failure must not stop a wake.
        pass
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def capability_notice(identity_path):
    """Path/interpreter are runtime configuration, never payload-selected."""
    try:
        notice, outcome = _result(_capture([
            sys.executable, str(Path(__file__).with_name("worker.py")),
            str(identity_path),
        ]))
    except (OSError, ValueError, TypeError, RecursionError, subprocess.SubprocessError):
        notice, outcome = FAILURE, "incomplete"
    # Existing runtime logging supplies timestamp/retention. No resident names,
    # requirements, paths, reasons, worker output or exception text are logged.
    try:
        log.info("capability_discovery outcome=%s", outcome)
    except Exception:
        # A broken logging sink must not stop an otherwise accepted trigger.
        pass
    _write_receipt(outcome)
    return notice
