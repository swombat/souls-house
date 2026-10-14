#!/usr/bin/python3
"""Small privileged entry point. No shell, caller paths, or caller revisions.

A Rails request may carry an expected revision ("rails expect <sha>"). That
can only make the deploy conditional: the worker still deploys master as it
clones it, and stops without deploying if master is no longer that commit.
A caller can never choose what ships.

A Chaos request may name upstream migration changes the owner has reviewed
("chaos accept <path>@<blob>,..."). Each entry is pinned to the exact blob the
running residents have; anything not listed still stops the rollout.

"acknowledge <job>" clears the latch left by that exact failed or interrupted
job, once its service has exited, so the next request can start."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path("/var/lib/house-deploy")
OPERATIONS = ("rails", "chaos", "both", "runtime")
TERMINAL = ("success", "failed", "partial", "interrupted", "superseded")
FIELDS = ("id", "operation", "state", "step", "rails_revision", "chaos_revision",
          "chaos_version", "skipped", "absent", "resident_id", "expected_revision",
          "accepted_migrations", "migration_changes", "acknowledged")
ACCEPT_ENTRY = re.compile(r"(?!.*\.\.)[A-Za-z0-9_][A-Za-z0-9_./-]{0,254}\.sql@[0-9a-f]{40}")
MAX_ACCEPTED = 20


def accepted_entries(spec):
    entries = spec.split(",")
    if not 1 <= len(entries) <= MAX_ACCEPTED or len(set(entries)) != len(entries):
        return None
    if not all(ACCEPT_ENTRY.fullmatch(entry) for entry in entries):
        return None
    return entries


def atomic(path, data):
    temp = path.with_suffix(f".{os.getpid()}.{uuid.uuid4().hex}.tmp")
    temp.write_text(json.dumps(data) + "\n")
    temp.replace(path)


def valid_args(args):
    return (len(args) == 1 and args[0] in OPERATIONS or
            len(args) == 2 and args[0] == "status" and
            re.fullmatch("[0-9a-f]{32}", args[1]) is not None or
            len(args) == 3 and args[:2] == ["rails", "expect"] and
            re.fullmatch("[0-9a-f]{40}", args[2]) is not None or
            len(args) == 3 and args[0] in ("chaos", "both") and args[1] == "accept" and
            accepted_entries(args[2]) is not None or
            len(args) == 2 and args[0] == "acknowledge" and
            re.fullmatch("[0-9a-f]{32}", args[1]) is not None)


def active(operation):
    return subprocess.run(
        ["/usr/bin/systemctl", "is-active", "--quiet", f"house-deploy-{operation}.service"],
        check=False).returncode == 0


def exited(operation):
    """Positively established exit: "not active" also covers activating,
    deactivating and query errors, none of which may release a latch."""
    result = subprocess.run(
        ["/usr/bin/systemctl", "show", "--property=ActiveState", "--value",
         f"house-deploy-{operation}.service"],
        check=False, capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() in ("inactive", "failed")


def status(job_id):
    data = json.loads((ROOT / "runs" / job_id / "status.json").read_text())
    if data["state"] not in TERMINAL and not active(data["operation"]):
        data.update(state="interrupted", step="worker stopped; operator inspection required")
        atomic(ROOT / "runs" / job_id / "status.json", data)
    # Never return a log, subprocess error, path, env value, or arbitrary file.
    return {key: data[key] for key in FIELDS if key in data}


def acknowledge(job_id):
    """Release the latch of this exact failed/interrupted job; nothing else."""
    current = ROOT / "current.json"
    if not current.exists() or json.loads(current.read_text())["id"] != job_id:
        raise RuntimeError("Not the latched deployment")
    result = status(job_id)
    if result["state"] not in ("failed", "interrupted") or not exited(result["operation"]):
        raise RuntimeError("Only an exited failed or interrupted deployment can be acknowledged")
    directory = ROOT / "runs" / job_id
    data = json.loads((directory / "status.json").read_text())
    data["acknowledged"] = True
    atomic(directory / "status.json", data)
    current.replace(directory / "acknowledged-current.json")
    return {key: data[key] for key in FIELDS if key in data}


def request(operation, expected=None, accepted=None):
    current = ROOT / "current.json"
    if current.exists():
        previous = json.loads(current.read_text())
        result = status(previous["id"])
        if result["state"] not in TERMINAL:
            # Join a running job only if it is the same request; a job with a
            # different expectation would report someone else's outcome.
            if (result["operation"] == operation and result.get("expected_revision") == expected
                    and result.get("accepted_migrations") == accepted):
                return result
            raise RuntimeError("Another deployment is running")
        if active(result["operation"]):
            raise RuntimeError("Previous service is still exiting")
        if result["state"] in ("failed", "interrupted"):
            raise RuntimeError("Failed or interrupted deployment requires operator inspection")
    job_id = uuid.uuid4().hex
    directory = ROOT / "runs" / job_id
    directory.mkdir(mode=0o700)
    data = dict(id=job_id, operation=operation, state="starting", step="accepted")
    if expected:
        data["expected_revision"] = expected
    if accepted:
        data["accepted_migrations"] = accepted
    atomic(directory / "status.json", data)
    atomic(current, data)
    try:
        subprocess.run(["/usr/bin/systemctl", "start", f"house-deploy-{operation}.service"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        data.update(state="failed", step="service could not start")
        atomic(directory / "status.json", data)
    return data


def main():
    os.umask(0o077)
    args = sys.argv[1:]
    if not valid_args(args):
        sys.exit("Unsupported deployment command")
    try:
        with (ROOT / "gate.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args[0] == "status":
                result = status(args[1])
            elif args[0] == "acknowledge":
                result = acknowledge(args[1])
            elif len(args) == 3 and args[1] == "accept":
                result = request(args[0], accepted=accepted_entries(args[2]))
            else:
                result = request(args[0], args[2] if len(args) == 3 else None)
        print(json.dumps(result))
    except (OSError, ValueError, RuntimeError):
        sys.exit("Deployment request unavailable; inspect host status")


if __name__ == "__main__":
    main()
