#!/usr/bin/env python3
"""House host runner: enrollment, telemetry and (when enabled) resident lifecycle.

Runs on a Hetzner Cloud VM ordered by the house. It dials out to Rails, so
it opens no inbound port. It enrolls once with a one-time token and then sends
signed heartbeats with facts about the host.

When its config says "commands_enabled": true it also polls Rails for
commands; Rails answers at once with at most one. The vocabulary is fixed here (start_resident, stop_resident,
submit_turn, turn_status, cancel_turn, seed_home, provider_auth) and anything else is refused locally,
whatever Rails asks. Rails supplies values, never Docker flags: the runner
builds every docker argv itself from a fixed template and validates each value
against a strict pattern. A turn is relayed to the resident's trigger server on
the VM's private Docker bridge, which is never published.

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
import http.client
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

SIGNATURE_VERSION = "souls-house-runner-v1"
CONFIG_PATH = "/etc/souls-house-runner/config.json"
STATE_DIR = "/var/lib/souls-house-runner"
METADATA_URL = "http://169.254.169.254/hetzner/v1/metadata/instance-id"
ENROLL_PATH = "/api/v1/host_runner/enrollment"
HEARTBEAT_PATH = "/api/v1/host_runner/heartbeat"
COMMAND_NEXT_PATH = "/api/v1/host_runner/commands/next"
COMMAND_RESULT_PATH = "/api/v1/host_runner/commands/{id}/result"
HEARTBEAT_SECONDS = 60
COMMAND_IDLE_SECONDS = 5
ENROLL_BACKOFF_SECONDS = (5, 15, 30, 60, 120, 300)

# The runner's whole vocabulary. Anything else is refused here, not only in
# Rails.
COMMAND_KINDS = frozenset({"start_resident", "stop_resident", "submit_turn", "turn_status", "cancel_turn", "seed_home",
                           "backup_resident", "provider_auth"})
ALLOWED_ACTIONS = frozenset({"report_facts", "heartbeat"}) | COMMAND_KINDS


class RefusedAction(Exception):
    pass


class BadOrigin(Exception):
    pass


def validate_origin(url):
    """The runner sends its one-time token to this origin, so it must be a
    bare HTTPS origin: no credentials, path, query or fragment."""
    parts = urllib.parse.urlsplit(url or "")
    if (
        parts.scheme != "https" or not parts.hostname or parts.username or parts.password
        or parts.path not in ("", "/") or parts.query or parts.fragment
    ):
        raise BadOrigin(f"rails_url must be a bare https origin: {url!r}")
    return f"https://{parts.netloc}"


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


def post(base_url, path, payload, key, runner_id, opener=urllib.request.urlopen, timeout=30):
    body = encode_body(payload)
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=body,
        method="POST",
        headers=signed_headers(key, "POST", path, body, runner_id),
    )
    try:
        with opener(request, timeout=timeout) as response:
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


# --- commands ---------------------------------------------------------------
#
# A command arrives as {"id", "kind", "generation", "payload"}. The runner
# answers each one exactly once with a signed result. Results are remembered by
# id, so a redelivered command (lost ack, restart) gets the same answer and is
# not executed twice. Commands issued under an older placement generation than
# the highest this runner has seen are refused: a stale queue must not drive a
# newer placement. This is not a fencing protocol between two hosts.

RESIDENT_NETWORK = "souls-house-residents"
TRIGGER_PORT = 4000
REMEMBERED_RESULTS = 200

NAME_RE = re.compile(r"\A[a-z0-9][a-z0-9-]{0,62}\Z")
# Resident images are built on the house host and pushed to no registry, so
# the runner fetches one from the house by image ID and checks it after load.
IMAGE_RE = re.compile(r"\Asha256:[0-9a-f]{64}\Z")
COMMAND_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
DISPATCH_ID_RE = re.compile(r"\A[0-9a-f-]{36}\Z")
LEDGER_ID_RE = re.compile(r"\A[0-9A-Za-z_\-]{1,64}\Z")
ENV_KEY_RE = re.compile(r"\A[A-Z][A-Z0-9_]{0,63}\Z")
# The environment a resident may be given. Rails cannot add PATH, LD_PRELOAD,
# DOCKER_HOST or anything else that changes what the container is. Provider
# API keys are the account's own, as a local resident gets them (#246 parity);
# GitHub-import settings are still absent.
RESIDENT_ENV_KEYS = frozenset({
    "AGENT_ID", "AGENT_SLUG", "AGENT_PROVIDER", "AGENT_DEFAULT_MODEL",
    "TRIGGER_BEARER_TOKEN", "SOULSHOUSE_BEARER_TOKEN", "SOULSHOUSE_APP_URL",
    "SOULSHOUSE_ACTIVITY_ORIGIN", "HELIXKIT_BEARER_TOKEN", "HELIXKIT_APP_URL",
    "SOULSHOUSE_HOME_PROFILE", "SOULSHOUSE_PORTABLE_HOME_ID", "AGENT_REPO_PATH",
    "SOULSHOUSE_REQUIRE_HOUSE_TRUST", "TZ",
    "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY",
    "XAI_API_KEY", "ZAI_API_KEY", "MOONSHOT_API_KEY", "MINIMAX_API_KEY",
})
# External-service credentials (Gmail and the like), copied into the
# container before it starts, exactly as Agents::Sandbox does locally. The
# entrypoint moves it into tmpfs; it never reaches a volume.
SERVICE_MANIFEST_PATH = "/run/helixkit-source.yml"
SERVICE_MANIFEST_MAX_BYTES = 256 * 1024
# The provider-login calls a person makes from the house (AgentProviderAuthClient),
# relayed to the resident's trigger server. Nothing else is reachable this way.
PROVIDER_AUTH_CALLS = frozenset({
    ("GET", "/auth/capabilities"), ("GET", "/auth/status"), ("GET", "/auth/usage"),
    ("POST", "/auth/start"), ("POST", "/auth/cancel"), ("POST", "/auth/code"), ("POST", "/auth/disconnect"),
})
PROVIDER_AUTH_PARAMS = frozenset({"provider", "model", "refresh", "code"})
VOLUME_MOUNTS = (
    ("identity", "/home/agent/identity"),
    ("chaos", "/home/agent/.chaos"),
    ("repo", "/home/agent/repo"),
    ("work", "/home/agent/work"),
    ("state", "/home/agent/state"),
)
MEMORY_MB_RANGE = (256, 16384)
CPU_SHARES_RANGE = (2, 4096)


class BadCommand(Exception):
    """The command is malformed or outside the runner's vocabulary."""


class CommandFailed(Exception):
    """The command was valid but could not be carried out."""


class SeedRefused(BadCommand):
    """The identity volume is not in a state a seed may touch. Refused, and the
    volume is left exactly as it is for an operator."""


def _require(condition, message):
    if not condition:
        raise BadCommand(message)


def validate_command(command):
    _require(isinstance(command, dict), "command must be an object")
    _require(isinstance(command.get("id"), str) and COMMAND_ID_RE.match(command["id"]), "bad command id")
    _require(command.get("kind") in COMMAND_KINDS, f"command not allowed on this runner: {command.get('kind')!r}")
    generation = command.get("generation")
    _require(isinstance(generation, int) and not isinstance(generation, bool) and generation >= 1, "bad generation")
    _require(isinstance(command.get("payload"), dict), "payload must be an object")
    return command


def validate_resident_spec(payload):
    """Everything start_resident may set, checked value by value."""
    name = payload.get("container_name")
    _require(isinstance(name, str) and NAME_RE.match(name), "bad container_name")
    image = payload.get("image")
    _require(isinstance(image, str) and IMAGE_RE.match(image), "image must be a sha256 image ID")
    memory = payload.get("memory_mb")
    _require(isinstance(memory, int) and not isinstance(memory, bool)
             and MEMORY_MB_RANGE[0] <= memory <= MEMORY_MB_RANGE[1], "bad memory_mb")
    shares = payload.get("cpu_shares")
    _require(isinstance(shares, int) and not isinstance(shares, bool)
             and CPU_SHARES_RANGE[0] <= shares <= CPU_SHARES_RANGE[1], "bad cpu_shares")
    env = payload.get("env")
    _require(isinstance(env, dict), "env must be an object")
    for key, value in env.items():
        _require(isinstance(key, str) and ENV_KEY_RE.match(key) and key in RESIDENT_ENV_KEYS, f"env key not allowed: {key!r}")
        _require(isinstance(value, str) and "\n" not in value and "\r" not in value and "\0" not in value,
                 f"bad env value for {key}")
    _require(env.get("TRIGGER_BEARER_TOKEN"), "TRIGGER_BEARER_TOKEN required")
    _require("registry_auth" not in payload, "registry credentials are not accepted")
    manifest = payload.get("service_manifest")
    _require(manifest is None or (isinstance(manifest, str) and "\0" not in manifest
                                  and len(manifest.encode("utf-8")) <= SERVICE_MANIFEST_MAX_BYTES),
             "bad service_manifest")
    return {"container_name": name, "image": image, "memory_mb": memory, "cpu_shares": shares, "env": dict(env),
            "service_manifest": manifest}


def volume_name(container_name, role):
    return f"{container_name}-{role}"


def create_argv(spec, env_file):
    """The only docker create this runner ever issues. It mirrors the house's
    local container (Agents::Sandbox#run_container!): named volumes, the
    private bridge, the /run/helixkit tmpfs. No published ports, no host
    mounts, no Docker socket."""
    name = spec["container_name"]
    argv = [
        "docker", "create",
        "--name", name,
        "--hostname", name,
        "--label", "souls-house.resident=1",
        "--network", RESIDENT_NETWORK,
        "--restart", "unless-stopped",
        "--memory", f"{spec['memory_mb']}m",
        "--cpu-shares", str(spec["cpu_shares"]),
        "--tmpfs", "/run/helixkit:rw,noexec,nosuid,nodev,mode=0700",
        "--env-file", env_file,
    ]
    for role, path in VOLUME_MOUNTS:
        argv += ["-v", f"{volume_name(name, role)}:{path}"]
    argv.append(spec["image"])
    return argv


class CommandState:
    """Remembered results and the highest generation seen, on disk."""

    def __init__(self, state_dir):
        self.path = os.path.join(state_dir, "commands.json")
        self.data = {"highest_generation": 0, "results": {}, "order": []}
        if os.path.exists(self.path):
            with open(self.path) as handle:
                self.data = json.load(handle)

    def result_for(self, command_id):
        return self.data["results"].get(command_id)

    def stale(self, generation):
        return generation < self.data["highest_generation"]

    def started(self, command_id):
        return command_id in self.data.get("in_flight", {})

    def begin(self, command_id, generation):
        """Written before anything runs. If the runner dies mid-command, the
        redelivery finds this and answers "unknown" instead of running the
        command a second time; Rails reconciles the same turn by its id."""
        self.data.setdefault("in_flight", {})[command_id] = generation
        # The highest generation seen advances when a command starts, not
        # when it finishes: after a restart, an older generation stays refused.
        self.data["highest_generation"] = max(self.data["highest_generation"], generation)
        self._save()

    def record(self, command_id, generation, result):
        self.data.setdefault("in_flight", {}).pop(command_id, None)
        self.data["highest_generation"] = max(self.data["highest_generation"], generation)
        self.data["results"][command_id] = result
        self.data["order"].append(command_id)
        while len(self.data["order"]) > REMEMBERED_RESULTS:
            self.data["results"].pop(self.data["order"].pop(0), None)
        self._save()

    def _save(self):
        tmp = self.path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(self.data, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(tmp, self.path)


def _docker(argv, timeout=120):
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return False, str(error)
    return completed.returncode == 0, (completed.stdout if completed.returncode == 0 else completed.stderr).strip()


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """The relay talks to one resident on the private bridge. A redirect is
    answered as the 3xx it is, never followed with the trigger token."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_RELAY_OPENER = urllib.request.build_opener(_RefuseRedirects)


def _http(method, url, token, body=None, ledger_id=None, timeout=10, opener=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", "application/json")
    if ledger_id:
        request.add_header("X-Resident-Ledger-ID", ledger_id)
    try:
        with (opener or _RELAY_OPENER).open(request, timeout=timeout) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as error:
        raw, status = error.read(), error.code
    except OSError as error:
        raise CommandFailed(f"resident unreachable: {error}")
    try:
        parsed = json.loads(raw or b"{}")
    except ValueError:
        parsed = {"raw": raw.decode("utf-8", "replace")[:2000]}
    return {"status": status, "body": parsed}


class ResidentHost:
    """Carries out the six commands. Docker and HTTP are injected so tests
    can see exactly what would run."""

    def __init__(self, state_dir, docker=_docker, http=_http, sleep=time.sleep, load_image=None, fetch_seed=None, backup_request=None):
        self.state_dir = state_dir
        self.docker = docker
        self.http = http
        self.sleep = sleep
        # load_image(image_id) streams the image from the house into
        # `docker load`; returns (ok, error).
        self.load_image = load_image
        # fetch_seed(sha256, write) streams a seed archive from the house.
        self.fetch_seed = fetch_seed
        self.backup_request = backup_request
        self.current_command_id = None

    def _backup_marker(self):
        return os.path.join(self.state_dir, "pending-backup.json")

    def begin_backup_recovery(self, name):
        _require(isinstance(self.current_command_id, str) and
                 COMMAND_ID_RE.fullmatch(self.current_command_id), "backup command id is missing")
        self._write_private(self._backup_marker(), json.dumps({
            "command_id": self.current_command_id, "container_name": name}))

    def backup_recovery_facts(self):
        try:
            with open(os.path.join(self.state_dir, "recovered-backup.json")) as handle:
                return {"recovered_backup": json.load(handle)}
        except (OSError, ValueError):
            return {}

    def recover_backup(self):
        """Contain tools before unpausing a resident owned by a durable marker."""
        path = self._backup_marker()
        if not os.path.exists(path):
            return
        with open(path) as handle:
            marker = json.load(handle)
        name = marker.get("container_name")
        self._known_resident(name)
        _require(isinstance(marker.get("command_id"), str) and
                 COMMAND_ID_RE.fullmatch(marker["command_id"]), "invalid backup recovery marker")
        ok, output = self.docker(["docker", "ps", "-a", "--format", "{{.Names}}"])
        if not ok:
            raise CommandFailed("cannot inspect interrupted backup tools")
        tools = [tool for tool in output.splitlines()
                 if re.fullmatch(r"souls-house-backup-[0-9a-f]{24}", tool)]
        if tools:
            ok, _ = self.docker(["docker", "rm", "-f", *tools])
            if not ok:
                raise CommandFailed("cannot stop interrupted backup tools")
        ok, output = self.docker(["docker", "ps", "-a", "--format", "{{.Names}}"])
        if not ok or any(re.fullmatch(r"souls-house-backup-[0-9a-f]{24}", tool)
                         for tool in output.splitlines()):
            raise CommandFailed("interrupted backup tools not contained")
        from backup_proxy import _state
        state = _state(lambda argv, timeout: self.docker(argv), name, 10)
        if state["Paused"]:
            ok, _ = self.docker(["docker", "unpause", name])
            if not ok:
                raise CommandFailed("cannot recover interrupted backup pause")
        state = _state(lambda argv, timeout: self.docker(argv), name, 10)
        if state["Paused"] or state.get("Restarting") or state.get("Dead") or state.get("Status") not in ("running", "exited", "created"):
            raise CommandFailed("interrupted backup runtime remains uncertain")
        self._write_private(os.path.join(self.state_dir, "recovered-backup.json"),
                            json.dumps({**marker, "unpaused": True, "tools_stopped": True}))
        os.unlink(path)

    # Secrets for a resident live only in its root-owned env file.
    def _env_path(self, name):
        return os.path.join(self.state_dir, "residents", f"{name}.env")

    def _spec_path(self, name):
        return os.path.join(self.state_dir, "residents", f"{name}.json")

    def _manifest_path(self, name):
        return os.path.join(self.state_dir, "residents", f"{name}.services.yml")

    def _write_private(self, path, text):
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(tmp, path)
        directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def _known_resident(self, name):
        _require(isinstance(name, str) and NAME_RE.match(name), "bad container_name")
        path = self._spec_path(name)
        if not os.path.exists(path):
            raise CommandFailed(f"no resident {name} on this host")
        with open(path) as handle:
            return json.load(handle)

    def _trigger_url(self, name):
        ok, address = self.docker(["docker", "inspect", "--format",
                                   "{{(index .NetworkSettings.Networks \"%s\").IPAddress}}" % RESIDENT_NETWORK, name])
        if not ok or not re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", address or ""):
            raise CommandFailed(f"resident {name} has no address on the private bridge")
        return f"http://{address}:{TRIGGER_PORT}"

    def start_resident(self, payload):
        spec = validate_resident_spec(payload)
        name = spec["container_name"]
        ok, _ = self.docker(["docker", "network", "inspect", RESIDENT_NETWORK])
        if not ok:
            ok, error = self.docker(["docker", "network", "create", "--driver", "bridge", RESIDENT_NETWORK])
            if not ok:
                raise CommandFailed(f"could not create resident network: {error}")
        for role, _path in VOLUME_MOUNTS:
            ok, error = self.docker(["docker", "volume", "create", volume_name(name, role)])
            if not ok:
                raise CommandFailed(f"could not create volume {role}: {error}")
        self._pull(spec)
        env_text = "".join(f"{key}={value}\n" for key, value in sorted(spec["env"].items()))
        self._write_private(self._env_path(name), env_text)
        public_spec = {key: spec[key] for key in ("container_name", "image", "memory_mb", "cpu_shares")}
        # A digest of the whole env, values included, so a rotated token
        # recreates the container; the values themselves stay in the env file.
        public_spec["env_digest"] = hashlib.sha256(env_text.encode("utf-8")).hexdigest()
        manifest = spec["service_manifest"]
        if manifest is not None:
            self._write_private(self._manifest_path(name), manifest)
            # The manifest is copied in only at creation, so a changed one
            # recreates the container, as locally.
            public_spec["manifest_digest"] = hashlib.sha256(manifest.encode("utf-8")).hexdigest()
        previous = None
        if os.path.exists(self._spec_path(name)):
            with open(self._spec_path(name)) as handle:
                previous = json.load(handle)
        exists, _ = self.docker(["docker", "container", "inspect", name])
        # Recreate when anything about the container changed; volumes stay.
        if exists and previous != public_spec:
            self.docker(["docker", "rm", "-f", name])
            exists = False
        if not exists:
            ok, error = self.docker(create_argv(spec, self._env_path(name)))
            if not ok:
                raise CommandFailed(f"could not create container: {error}")
            if manifest is not None:
                ok, error = self.docker(["docker", "cp", self._manifest_path(name), f"{name}:{SERVICE_MANIFEST_PATH}"])
                if not ok:
                    self.docker(["docker", "rm", "-f", name])
                    raise CommandFailed(f"could not copy the service manifest: {error}")
        self._write_private(self._spec_path(name), json.dumps(public_spec))
        ok, error = self.docker(["docker", "start", name])
        if not ok:
            raise CommandFailed(f"could not start container: {error}")
        token = spec["env"]["TRIGGER_BEARER_TOKEN"]
        for _ in range(60):
            try:
                if self.http("GET", self._trigger_url(name) + "/health", token, timeout=3)["status"] == 200:
                    return {"state": "running", "container_name": name, "image": spec["image"]}
            except CommandFailed:
                pass
            self.sleep(2)
        raise CommandFailed("resident started but never answered /health")

    def _image_present(self, image_id):
        ok, found = self.docker(["docker", "image", "inspect", "--format", "{{.Id}}", image_id])
        return ok and found == image_id

    def _pull(self, spec):
        image_id = spec["image"]
        if self._image_present(image_id):
            return
        if self.load_image is None:
            raise CommandFailed("no way to fetch images on this runner")
        ok, error = self.load_image(image_id)
        if not ok:
            raise CommandFailed(f"could not fetch image: {error}")
        # The ID is the hash of the image config: whatever was loaded, only the
        # exact image asked for may run.
        if not self._image_present(image_id):
            raise CommandFailed("fetched image does not match the requested image ID")

    def stop_resident(self, payload):
        name = payload.get("container_name")
        self._known_resident(name)
        ok, error = self.docker(["docker", "stop", "--time", "30", name])
        if not ok:
            raise CommandFailed(f"could not stop container: {error}")
        return {"state": "stopped", "container_name": name}

    def _turn(self, method, payload, suffix=""):
        name = payload.get("container_name")
        self._known_resident(name)
        dispatch_id = payload.get("dispatch_id")
        _require(isinstance(dispatch_id, str) and DISPATCH_ID_RE.match(dispatch_id), "bad dispatch_id")
        ledger_id = payload.get("ledger_id")
        _require(ledger_id is None or (isinstance(ledger_id, str) and LEDGER_ID_RE.match(ledger_id)), "bad ledger_id")
        body = payload.get("body")
        _require(body is None or isinstance(body, dict), "body must be an object")
        with open(self._env_path(name)) as handle:
            token = next(line.split("=", 1)[1].strip() for line in handle if line.startswith("TRIGGER_BEARER_TOKEN="))
        url = f"{self._trigger_url(name)}/turns/{dispatch_id}{suffix}"
        return self.http(method, url, token, body=body, ledger_id=ledger_id)

    def submit_turn(self, payload):
        return self._turn("POST", payload)

    def turn_status(self, payload):
        return self._turn("GET", payload)

    def cancel_turn(self, payload):
        return self._turn("DELETE", payload)

    def provider_auth(self, payload):
        """One provider-login call, relayed to the resident's trigger server.
        Only the fixed calls in PROVIDER_AUTH_CALLS, with fixed parameter
        names; the answer is returned whatever its status."""
        name = payload.get("container_name")
        self._known_resident(name)
        method = payload.get("method")
        path = payload.get("path")
        _require((method, path) in PROVIDER_AUTH_CALLS, f"provider auth call not allowed: {method} {path}")
        params = payload.get("params") or {}
        _require(isinstance(params, dict), "params must be an object")
        for key, value in params.items():
            _require(key in PROVIDER_AUTH_PARAMS, f"provider auth parameter not allowed: {key!r}")
            _require(value is None or isinstance(value, (str, int)) and not isinstance(value, bool),
                     f"bad provider auth parameter {key}")
            _require(not isinstance(value, str) or len(value) <= 4096, f"provider auth parameter too long: {key}")
        params = {key: value for key, value in params.items() if value is not None}
        with open(self._env_path(name)) as handle:
            token = next(line.split("=", 1)[1].strip() for line in handle if line.startswith("TRIGGER_BEARER_TOKEN="))
        url = self._trigger_url(name) + path
        if method == "GET":
            if params:
                url += "?" + urllib.parse.urlencode(params)
            return self.http("GET", url, token, timeout=20)
        return self.http("POST", url, token, body=params or None, timeout=20)

    def backup_resident(self, payload):
        from backup_proxy import run_backup
        if self.backup_request is None:
            raise BadCommand("backup transport unavailable")
        _require(isinstance(self.current_command_id, str) and
                 COMMAND_ID_RE.fullmatch(self.current_command_id), "backup command id is missing")
        self._known_resident(payload.get("container_name"))
        result = None
        try:
            result = run_backup(payload, self, signed_request=self.backup_request)
            return result
        except (BadCommand, CommandFailed) as error:
            result = getattr(error, "result", None)
            raise
        finally:
            if isinstance(result, dict) and result.get("unpaused") is True and result.get("tools_stopped") is True and os.path.exists(self._backup_marker()):
                os.unlink(self._backup_marker())

    # seed_home (#246 slice 3): the first contents of a new resident's
    # identity volume, before its first start. The archive comes from the
    # house by digest, is checked against that digest, and is unpacked into a
    # staging directory inside the volume, then moved into place. A marker
    # holding the digest is written last, so a retry after a lost answer is
    # recognised as done. Anything else already in the volume is refused and
    # never wiped.
    def _volume_mountpoint(self, volume):
        ok, error = self.docker(["docker", "volume", "create", volume])
        if not ok:
            raise CommandFailed(f"could not create volume {volume}: {error}")
        ok, mountpoint = self.docker(["docker", "volume", "inspect", "--format", "{{.Mountpoint}}", volume])
        if not ok or not mountpoint.startswith("/") or not os.path.isdir(mountpoint):
            raise CommandFailed(f"volume {volume} has no local mountpoint")
        return mountpoint

    def seed_home(self, payload):
        name = payload.get("container_name")
        _require(isinstance(name, str) and NAME_RE.match(name), "bad container_name")
        digest = payload.get("sha256")
        _require(isinstance(digest, str) and SEED_DIGEST_RE.match(digest), "bad sha256")
        size = payload.get("bytes")
        _require(isinstance(size, int) and not isinstance(size, bool) and 0 < size <= SEED_MAX_BYTES, "bad bytes")
        root = self._volume_mountpoint(volume_name(name, "identity"))
        marker = os.path.join(root, SEED_MARKER)
        if os.path.lexists(marker):
            if read_seed_marker(marker) == digest:
                return {"state": "seeded", "sha256": digest, "already": True}
            raise SeedRefused("identity volume was seeded from a different archive")
        if os.listdir(root):
            raise SeedRefused("identity volume is not empty and has no seed marker")
        if self.fetch_seed is None:
            raise CommandFailed("no way to fetch seed archives on this runner")
        spool_dir = os.path.join(self.state_dir, "seeds")
        os.makedirs(spool_dir, mode=0o700, exist_ok=True)
        with tempfile.TemporaryFile(dir=spool_dir) as spool:
            hasher = hashlib.sha256()
            received = [0]

            def write(chunk):
                received[0] += len(chunk)
                if received[0] > size:
                    raise CommandFailed("seed archive is larger than announced")
                hasher.update(chunk)
                spool.write(chunk)

            ok, error = self.fetch_seed(digest, write)
            if not ok:
                raise CommandFailed(f"could not fetch seed archive: {error}")
            if received[0] != size or hasher.hexdigest() != digest:
                raise CommandFailed("seed archive does not match its digest")
            spool.seek(0)
            entries = unpack_seed(spool, os.path.join(root, SEED_STAGING))
        staging = os.path.join(root, SEED_STAGING)
        for entry in sorted(os.listdir(staging)):
            os.rename(os.path.join(staging, entry), os.path.join(root, entry))
        os.rmdir(staging)
        tmp = marker + ".tmp"
        with open(tmp, "w") as handle:
            handle.write(digest + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(tmp, marker)
        return {"state": "seeded", "sha256": digest, "already": False, "entries": entries}


def execute_command(command, state, host):
    """Validate, dedupe, refuse stale generations, run, remember. Returns the
    result to report; never raises for a bad or failed command."""
    try:
        validate_command(command)
    except BadCommand as error:
        command_id = command.get("id") if isinstance(command, dict) else None
        return command_id, {"outcome": "refused", "error": str(error)}
    remembered = state.result_for(command["id"])
    if remembered is not None:
        return command["id"], remembered
    if state.started(command["id"]):
        result = {"outcome": "unknown", "error": "runner restarted while this command was running"}
    elif state.stale(command["generation"]):
        result = {"outcome": "refused", "error": "stale generation"}
    else:
        state.begin(command["id"], command["generation"])
        try:
            host.current_command_id = command["id"]
            result = {"outcome": "done", "result": getattr(host, command["kind"])(command["payload"])}
        except BadCommand as error:
            result = {"outcome": "refused", "error": str(error)}
            if isinstance(getattr(error, "result", None), dict):
                result["result"] = error.result
        except CommandFailed as error:
            result = {"outcome": "failed", "error": str(error)}
            if isinstance(getattr(error, "result", None), dict):
                result["result"] = error.result
        except Exception as error:  # the effect may or may not have happened
            result = {"outcome": "unknown", "error": f"{type(error).__name__}: {error}"}
    state.record(command["id"], command["generation"], result)
    return command["id"], result


IMAGE_PATH = "/api/v1/host_runner/images/{id}"
IMAGE_CHUNK = 1024 * 1024

SEED_PATH = "/api/v1/host_runner/seeds/{id}"
SEED_DIGEST_RE = re.compile(r"\A[0-9a-f]{64}\Z")
SEED_MARKER = ".souls-house-seed"
SEED_STAGING = ".souls-house-seed-staging"
SEED_MAX_BYTES = 64 * 1024 * 1024
SEED_MAX_UNPACKED = 256 * 1024 * 1024
SEED_MAX_ENTRIES = 20000
SEED_DEADLINE = 10 * 60


def _seed_member_path(name):
    """A relative path with no '..', no absolute part and no empty segment."""
    _require(isinstance(name, str) and name and "\0" not in name, "seed entry has a bad name")
    name = name[2:] if name.startswith("./") else name
    name = name.rstrip("/")
    _require(name and not name.startswith("/") and "\\" not in name, f"seed entry is not relative: {name!r}")
    parts = name.split("/")
    _require(all(part not in ("", ".", "..") for part in parts), f"seed entry escapes the home: {name!r}")
    return parts


SEED_MARKER_MAX_BYTES = 128


def read_seed_marker(path):
    """The marker's contents, if it is a small regular file. A symlink is
    never followed (it could point anywhere and vouch for a seed that never
    happened), a FIFO or device is never read (it could block), and anything
    else is refused rather than trusted."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise SeedRefused(f"seed marker is not a regular file: {error.strerror}")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SeedRefused("seed marker is not a regular file")
        if info.st_size > SEED_MARKER_MAX_BYTES:
            raise SeedRefused("seed marker is too large")
        return os.read(fd, SEED_MARKER_MAX_BYTES + 1).decode("utf-8", "replace").strip()
    finally:
        os.close(fd)


def unpack_seed(fileobj, staging):
    """Unpack a gzipped tar into staging, which must not exist. Every member
    is checked before anything is written: regular files and directories
    only, relative paths, bounded count and size. Files are written by hand,
    never by tarfile.extract, so no owner, link or device from the archive
    reaches the disk. Returns the number of entries."""
    try:
        archive = tarfile.open(fileobj=fileobj, mode="r:gz")
    except (tarfile.TarError, OSError, EOFError) as error:
        raise CommandFailed(f"seed archive is not a gzipped tar: {error}")
    with archive:
        # Members are read one at a time and every limit applies as each is
        # met, so a hostile archive is refused at the cap, never parsed whole.
        total = 0
        plan = []
        while True:
            try:
                member = archive.next()
            except (tarfile.TarError, OSError, EOFError) as error:
                raise CommandFailed(f"seed archive is unreadable: {error}")
            if member is None:
                break
            _require(len(plan) < SEED_MAX_ENTRIES, "seed archive has too many entries")
            parts = _seed_member_path(member.name)
            _require(member.isfile() or member.isdir(), f"seed entry is not a file or directory: {member.name!r}")
            total += member.size if member.isfile() else 0
            _require(total <= SEED_MAX_UNPACKED, "seed archive unpacks too large")
            plan.append((member, parts))
        os.mkdir(staging, 0o700)
        for member, parts in plan:
            target = os.path.join(staging, *parts)
            if member.isdir():
                os.makedirs(target, mode=0o755, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644 | (member.mode & 0o111))
            with os.fdopen(fd, "wb") as handle, archive.extractfile(member) as source:
                remaining = member.size
                while remaining > 0:
                    chunk = source.read(min(IMAGE_CHUNK, remaining))
                    if not chunk:
                        raise CommandFailed(f"seed entry is truncated: {member.name!r}")
                    handle.write(chunk)
                    remaining -= len(chunk)
        return len(plan)


def fetch_seed(config, key, digest, write, opener=None, deadline=SEED_DEADLINE):
    """Signed GET of one seed archive from the house. Same rules as an image:
    no redirects, bounded in time. Returns (ok, error); CommandFailed raised by
    write() (an oversized archive) propagates."""
    if not SEED_DIGEST_RE.match(digest or ""):
        return False, "bad seed digest"
    path = SEED_PATH.format(id=digest)
    request = urllib.request.Request(config["rails_url"].rstrip("/") + path, method="GET",
                                     headers=signed_headers(key, "GET", path, b"", config["runner_id"]))
    ends_at = time.monotonic() + deadline
    try:
        with (opener or _IMAGE_OPENER.open)(request, timeout=60) as response:
            if response.status != 200:
                return False, f"house answered {response.status}"
            read = response.read1 if hasattr(response, "read1") else response.read
            while True:
                if time.monotonic() >= ends_at:
                    return False, "seed fetch passed its deadline"
                chunk = read(IMAGE_CHUNK)
                if not chunk:
                    return True, ""
                write(chunk)
    except urllib.error.HTTPError as error:
        return False, f"house answered {error.code}"
    except (OSError, ValueError, http.client.HTTPException) as error:
        return False, f"{type(error).__name__}: {error}"


# The image comes from the house and nowhere else: a redirect is answered as
# the 3xx it is, so no redirected byte reaches docker load and the signature
# headers never leave for another host.
_IMAGE_OPENER = urllib.request.build_opener(_RefuseRedirects)


def fetch_image(config, key, image_id, write, opener=_IMAGE_OPENER.open, deadline=None):
    """Signed GET of one image from the house, streamed into write().
    Returns (ok, error); never raises. deadline is a time.monotonic() value:
    past it, the fetch stops at its next read."""
    if not IMAGE_RE.match(image_id or ""):
        return False, "bad image ID"
    path = IMAGE_PATH.format(id=image_id)
    request = urllib.request.Request(config["rails_url"].rstrip("/") + path, method="GET",
                                     headers=signed_headers(key, "GET", path, b"", config["runner_id"]))
    try:
        with opener(request, timeout=60) as response:
            if response.status != 200:
                return False, f"house answered {response.status}"
            # read1 returns after one receive, so a slow drip cannot hold a
            # single read open past the deadline check.
            read = response.read1 if hasattr(response, "read1") else response.read
            while True:
                if deadline is not None and time.monotonic() >= deadline:
                    return False, "image fetch passed its deadline"
                chunk = read(IMAGE_CHUNK)
                if not chunk:
                    return True, ""
                write(chunk)
    except (OSError, ValueError, http.client.HTTPException) as error:
        return False, f"{type(error).__name__}: {error}"


# docker load runs inside the command loop, which also carries heartbeats and
# later stop commands, so the whole call is bounded by one absolute deadline:
# the fetch runs in a worker thread that the loop stops waiting for at the
# deadline (the worker itself stops at its next read or write); stderr is
# drained concurrently, keeping only its tail, so neither side can block on a
# full pipe; and whatever happens, the child is killed if still running and
# reaped before this returns.
LOAD_DEADLINE = 30 * 60
LOAD_STDERR_TAIL = 4096


def _drain_tail(stream, keep):
    tail = bytearray()

    def run():
        for chunk in iter(lambda: stream.read(4096), b""):
            tail.extend(chunk)
            del tail[:-keep]

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, tail


def docker_load_from_house(config, key, popen=subprocess.Popen, fetch=fetch_image, deadline=LOAD_DEADLINE):
    def load(image_id):
        ends_at = time.monotonic() + deadline
        try:
            process = popen(["docker", "load"], stdin=subprocess.PIPE,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except OSError as error:
            return False, str(error)
        outcome = {}

        def run():
            try:
                outcome["result"] = fetch(config, key, image_id, process.stdin.write, deadline=ends_at)
            except OSError:
                outcome["result"] = (False, "docker load stopped reading")
            except Exception as error:  # never let the worker die silently
                outcome["result"] = (False, f"image fetch failed: {type(error).__name__}: {error}")

        timed_out = False
        code = None
        drainer = None
        tail = bytearray()
        try:
            drainer, tail = _drain_tail(process.stderr, LOAD_STDERR_TAIL)
            worker = threading.Thread(target=run, daemon=True)
            worker.start()
            worker.join(max(0.0, ends_at - time.monotonic()))
            timed_out = worker.is_alive()
            ok, error = outcome.get("result", (False, "image fetch did not finish"))
            if timed_out or not ok:
                process.kill()
            try:
                process.stdin.close()
            except (OSError, ValueError):
                pass
            try:
                code = process.wait(timeout=max(0.0, ends_at - time.monotonic()))
            except subprocess.TimeoutExpired:
                timed_out = True
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            if drainer is not None:
                drainer.join(timeout=5)
        if timed_out:
            return False, f"docker load did not finish within {deadline} seconds"
        if not ok:
            return False, error or "image fetch failed"
        if code != 0:
            return False, bytes(tail[-500:]).decode("utf-8", "replace") or "docker load failed"
        return True, ""
    return load


def poll_command_once(config, key, state, host, opener=urllib.request.urlopen):
    """One poll. Returns True when a command was handled."""
    status, body = post(config["rails_url"], COMMAND_NEXT_PATH, {}, key, config["runner_id"], opener=opener)
    if status != 200 or not isinstance(body.get("command"), dict):
        return False
    command_id, result = execute_command(body["command"], state, host)
    if command_id is None or not COMMAND_ID_RE.match(command_id):
        return True
    post(config["rails_url"], COMMAND_RESULT_PATH.format(id=command_id), result, key, config["runner_id"], opener=opener)
    return True


def poll_with_heartbeats(poll, config, key, state, host, heartbeat, facts, interval=HEARTBEAT_SECONDS):
    stop = threading.Event()

    def beats():
        while not stop.wait(interval):
            try:
                heartbeat(config, key, {**facts(config.get("runtime_image")), **host.backup_recovery_facts()})
            except Exception as error:
                print(f"heartbeat failed: {type(error).__name__}", file=sys.stderr)

    thread = threading.Thread(target=beats, daemon=True)
    thread.start()
    try:
        recover = getattr(host, "recover_backup", None)
        if callable(recover):
            # A failed cleanup need not wait for a process restart. Contain
            # the marked backup before allowing any later command to run.
            recover()
        return poll(config, key, state, host)
    finally:
        stop.set()
        thread.join(timeout=35)


def main(config_path=CONFIG_PATH, state_dir=STATE_DIR, sleep=time.sleep, enroll=enroll_once, heartbeat=heartbeat_once,
         facts=collect_facts, max_heartbeats=None, poll=poll_command_once, clock=time.monotonic):
    with open(config_path) as handle:
        config = json.load(handle)
    try:
        config["rails_url"] = validate_origin(config.get("rails_url"))
    except BadOrigin as error:
        print(f"{error}; needs operator review", file=sys.stderr)
        return 4
    key = load_or_create_key(state_dir)
    marker = os.path.join(state_dir, "enrolled")
    if os.path.exists(marker) and "enrollment_token" in config:
        # A crash between writing the marker and dropping the spent token.
        forget_token(config_path)
        config.pop("enrollment_token", None)

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
            # A lost enrollment reply past the token's lifetime: the pinned key
            # still works, and a signed heartbeat is how that is discovered.
            if heartbeat(config, key, facts(config.get("runtime_image"))) == 200:
                open(marker, "w").close()
                forget_token(config_path)
                break
            print("enrollment refused; needs operator review", file=sys.stderr)
            return 3
        sleep(ENROLL_BACKOFF_SECONDS[min(attempt, len(ENROLL_BACKOFF_SECONDS) - 1)])
        attempt += 1

    sent = 0
    if config.get("commands_enabled") is True:
        # Heartbeats keep their cadence; between them the runner polls for
        # commands, pausing COMMAND_IDLE_SECONDS when there is nothing to do.
        state = CommandState(state_dir)
        from backup_proxy import make_signed_request
        host = ResidentHost(state_dir, sleep=sleep, load_image=docker_load_from_house(config, key),
                            fetch_seed=lambda digest, write: fetch_seed(config, key, digest, write),
                            backup_request=make_signed_request(config, key, signed_headers))
        host.recover_backup()
        last_beat = None
        while max_heartbeats is None or sent < max_heartbeats:
            if last_beat is None or clock() - last_beat >= HEARTBEAT_SECONDS:
                heartbeat(config, key, {**facts(config.get("runtime_image")), **host.backup_recovery_facts()})
                sent += 1
                last_beat = clock()
            try:
                handled = poll_with_heartbeats(poll, config, key, state, host, heartbeat, facts)
            except Exception as error:  # a broken poll must not stop heartbeats
                print(f"command poll failed: {error}", file=sys.stderr)
                handled = False
            if not handled:
                sleep(COMMAND_IDLE_SECONDS)
        return 0
    while max_heartbeats is None or sent < max_heartbeats:
        heartbeat(config, key, facts(config.get("runtime_image")))
        sent += 1
        sleep(HEARTBEAT_SECONDS)
    return 0


if __name__ == "__main__":
    # Keep one set of command exception types for the backup module.
    sys.modules.setdefault("souls_house_runner", sys.modules[__name__])
    signal.signal(signal.SIGTERM, lambda _signal, _frame: sys.exit(143))
    sys.exit(main())
