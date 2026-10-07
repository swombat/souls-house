#!/usr/bin/env python3
"""House host runner: pilot enrollment and telemetry only.

Runs on a Hetzner Cloud VM ordered by the house. It dials out to Rails, so
it opens no inbound port. It enrolls once with a one-time token and then sends
signed heartbeats with facts about the host. It runs nothing on behalf of
residents: the only actions it knows are report_facts and heartbeat, and it
refuses anything else, whatever Rails asks.

Wire contract (shared with app/lib/runner_signature.rb):

  signed string = "souls-house-runner-v1" LF method LF path LF
                  sha256-hex(body) LF runner-id LF unix-seconds LF nonce
  headers       = X-Runner-Id, X-Runner-Timestamp, X-Runner-Nonce,
                  X-Runner-Signature (base64 Ed25519 signature)

Dependencies: the Python stdlib plus python3-cryptography (Debian package),
used only for Ed25519. No cryptography is implemented here.
"""

import base64
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

SIGNATURE_VERSION = "souls-house-runner-v1"
CONFIG_PATH = "/etc/souls-house-runner/config.json"
STATE_DIR = "/var/lib/souls-house-runner"
METADATA_URL = "http://169.254.169.254/hetzner/v1/metadata/instance-id"
ENROLL_PATH = "/api/v1/host_runner/enrollment"
HEARTBEAT_PATH = "/api/v1/host_runner/heartbeat"
HEARTBEAT_SECONDS = 60
ENROLL_BACKOFF_SECONDS = (5, 15, 30, 60, 120, 300)

# The runner's whole vocabulary in this slice. Anything else is refused here,
# not only in Rails.
ALLOWED_ACTIONS = frozenset({"report_facts", "heartbeat"})


class RefusedAction(Exception):
    pass


def require_allowed(action):
    if action not in ALLOWED_ACTIONS:
        raise RefusedAction(f"action not allowed on this runner: {action!r}")
    return action


# --- keys -------------------------------------------------------------------

def load_or_create_key(state_dir=STATE_DIR):
    """Generate the keypair once and keep it. The same key is reused across
    retries and reboots, so a lost enrollment reply can be recovered."""
    path = os.path.join(state_dir, "runner_ed25519.key")
    if os.path.exists(path):
        with open(path, "rb") as handle:
            return Ed25519PrivateKey.from_private_bytes(handle.read())
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    key = Ed25519PrivateKey.generate()
    raw = key.private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(raw)
        handle.flush()
        os.fsync(handle.fileno())
    os.rename(tmp, path)
    return key


def public_key_b64(key):
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode("ascii")


# --- signing ----------------------------------------------------------------

def signing_string(method, path, body, runner_id, timestamp, nonce):
    digest = hashlib.sha256(body).hexdigest()
    return "\n".join([SIGNATURE_VERSION, method.upper(), path, digest, runner_id, str(timestamp), nonce])


def signed_headers(key, method, path, body, runner_id, timestamp=None, nonce=None):
    timestamp = int(time.time()) if timestamp is None else int(timestamp)
    nonce = secrets.token_hex(16) if nonce is None else nonce
    message = signing_string(method, path, body, runner_id, timestamp, nonce).encode("utf-8")
    signature = base64.b64encode(key.sign(message)).decode("ascii")
    return {
        "Content-Type": "application/json",
        "X-Runner-Id": runner_id,
        "X-Runner-Timestamp": str(timestamp),
        "X-Runner-Nonce": nonce,
        "X-Runner-Signature": signature,
    }


# --- facts ------------------------------------------------------------------

def _run(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None


def provider_server_id(url=METADATA_URL):
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            value = response.read().decode("ascii").strip()
        return int(value) if value.isdigit() else None
    except (OSError, ValueError):
        return None


def memory_total_kib(path="/proc/meminfo"):
    try:
        with open(path) as handle:
            for line in handle:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def uptime_seconds(path="/proc/uptime"):
    try:
        with open(path) as handle:
            return int(float(handle.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return None


def collect_facts(runtime_image=None, server_id_reader=provider_server_id, command_runner=_run):
    require_allowed("report_facts")
    disk = shutil.disk_usage("/")
    image_digest = None
    if runtime_image:
        image_digest = command_runner(["docker", "image", "inspect", "--format", "{{index .RepoDigests 0}}", runtime_image])
    return {
        "provider_server_id": server_id_reader(),
        "docker_version": command_runner(["docker", "version", "--format", "{{.Server.Version}}"]),
        "runtime_image_digest": image_digest,
        "disk_total_bytes": disk.total,
        "disk_free_bytes": disk.free,
        "memory_total_kib": memory_total_kib(),
        "uptime_seconds": uptime_seconds(),
        "runner_version": SIGNATURE_VERSION,
    }


# --- transport --------------------------------------------------------------

def encode_body(payload):
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")


def post(base_url, path, payload, key, runner_id, opener=urllib.request.urlopen):
    body = encode_body(payload)
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=body,
        method="POST",
        headers=signed_headers(key, "POST", path, body, runner_id),
    )
    try:
        with opener(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try:
            parsed = json.loads(error.read() or b"{}")
        except ValueError:
            parsed = {}
        return error.code, parsed
    except (OSError, ValueError):
        return None, {}


def enroll_once(config, key, facts, opener=urllib.request.urlopen):
    """One enrollment attempt. Returns 'enrolled', 'pending' or 'refused'.

    'pending' covers both "Rails has not confirmed this server yet" (the token
    is not burned) and transport trouble. Either way the runner retries with
    the same key and token. A burned token sent again with the same key is
    answered as already enrolled, which is how a lost reply recovers.
    """
    payload = {"token": config["enrollment_token"], "public_key": public_key_b64(key), "facts": facts}
    status, body = post(config["rails_url"], ENROLL_PATH, payload, key, config["runner_id"], opener=opener)
    if status == 200 and body.get("status") in ("enrolled", "already_enrolled"):
        return "enrolled"
    if status is None or status == 202 or status == 429 or status >= 500:
        return "pending"
    if status == 401 and body.get("error") == "clock_skew":
        # Early boot before time sync; the same request will verify later.
        return "pending"
    return "refused"


def heartbeat_once(config, key, facts, opener=urllib.request.urlopen):
    require_allowed("heartbeat")
    status, _ = post(config["rails_url"], HEARTBEAT_PATH, {"facts": facts}, key, config["runner_id"], opener=opener)
    return status


def forget_token(config_path=CONFIG_PATH):
    """After enrollment the token is spent; drop it from disk."""
    with open(config_path) as handle:
        config = json.load(handle)
    if "enrollment_token" not in config:
        return
    config.pop("enrollment_token")
    tmp = config_path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(config, handle)
    os.rename(tmp, config_path)


def main(config_path=CONFIG_PATH, state_dir=STATE_DIR, sleep=time.sleep, enroll=enroll_once, heartbeat=heartbeat_once,
         facts=collect_facts, max_heartbeats=None):
    with open(config_path) as handle:
        config = json.load(handle)
    key = load_or_create_key(state_dir)
    marker = os.path.join(state_dir, "enrolled")

    attempt = 0
    while not os.path.exists(marker):
        if "enrollment_token" not in config:
            print("no enrollment token and not enrolled; needs operator review", file=sys.stderr)
            return 2
        outcome = enroll(config, key, facts(config.get("runtime_image")))
        if outcome == "enrolled":
            open(marker, "w").close()
            forget_token(config_path)
            break
        if outcome == "refused":
            print("enrollment refused; needs operator review", file=sys.stderr)
            return 3
        sleep(ENROLL_BACKOFF_SECONDS[min(attempt, len(ENROLL_BACKOFF_SECONDS) - 1)])
        attempt += 1

    sent = 0
    while max_heartbeats is None or sent < max_heartbeats:
        heartbeat(config, key, facts(config.get("runtime_image")))
        sent += 1
        sleep(HEARTBEAT_SECONDS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
