#!/usr/bin/python3
"""Small privileged entry point. No shell, caller paths, or caller revisions."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path("/var/lib/house-deploy")
OPERATIONS = ("rails", "chaos", "both")
TERMINAL = ("success", "failed", "partial", "interrupted")
FIELDS = ("id", "operation", "state", "step", "rails_revision", "chaos_revision",
          "chaos_version", "skipped", "resident_id")


def atomic(path, data):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data) + "\n")
    temp.replace(path)


def valid_args(args):
    return (len(args) == 1 and args[0] in OPERATIONS or
            len(args) == 2 and args[0] == "status" and
            re.fullmatch("[0-9a-f]{32}", args[1]) is not None)


def active(operation):
    return subprocess.run(
        ["/usr/bin/systemctl", "is-active", "--quiet", f"house-deploy-{operation}.service"],
        check=False).returncode == 0


def status(job_id):
    data = json.loads((ROOT / "runs" / job_id / "status.json").read_text())
    if data["state"] not in TERMINAL and not active(data["operation"]):
        data.update(state="interrupted", step="worker stopped; operator inspection required")
        atomic(ROOT / "runs" / job_id / "status.json", data)
    # Never return a log, subprocess error, path, env value, or arbitrary file.
    return {key: data[key] for key in FIELDS if key in data}


def request(operation):
    current = ROOT / "current.json"
    if current.exists():
        previous = json.loads(current.read_text())
        result = status(previous["id"])
        if result["state"] not in TERMINAL:
            if result["operation"] == operation:
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
            result = status(args[1]) if args[0] == "status" else request(args[0])
        print(json.dumps(result))
    except (OSError, ValueError, RuntimeError):
        sys.exit("Deployment request unavailable; inspect host status")


if __name__ == "__main__":
    main()
