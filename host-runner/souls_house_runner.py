#!/usr/bin/env python3
"""House host runner: enrollment, telemetry and (when enabled) resident lifecycle.

Runs on a Hetzner Cloud VM ordered by the house. It dials out to Rails, so
it opens no inbound port. It enrolls once with a one-time token and then sends
signed heartbeats with facts about the host.

When its config says "commands_enabled": true it also long-polls Rails for
commands. The vocabulary is fixed here (start_resident, stop_resident,
submit_turn, turn_status, cancel_turn) and anything else is refused locally,
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
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
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
COMMAND_POLL_TIMEOUT_SECONDS = 40
ENROLL_BACKOFF_SECONDS = (5, 15, 30, 60, 120, 300)

# The runner's whole vocabulary. Anything else is refused here, not only in
# Rails.
COMMAND_KINDS = frozenset({"start_resident", "stop_resident", "submit_turn", "turn_status", "cancel_turn"})
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
IMAGE_RE = re.compile(r"\A[a-z0-9][a-z0-9.\-]*(?::[0-9]{1,5})?(?:/[a-z0-9][a-z0-9._\-]*)+@sha256:[0-9a-f]{64}\Z")
COMMAND_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
DISPATCH_ID_RE = re.compile(r"\A[0-9a-f-]{36}\Z")
LEDGER_ID_RE = re.compile(r"\A[0-9A-Za-z_\-]{1,64}\Z")
ENV_KEY_RE = re.compile(r"\A[A-Z][A-Z0-9_]{0,63}\Z")
# The environment a resident may be given. Rails cannot add PATH, LD_PRELOAD,
# DOCKER_HOST or anything else that changes what the container is. This slice
# runs house-inference residents only, so provider API keys and GitHub-import
# settings are deliberately absent.
RESIDENT_ENV_KEYS = frozenset({
    "AGENT_ID", "AGENT_SLUG", "AGENT_PROVIDER", "AGENT_DEFAULT_MODEL",
    "TRIGGER_BEARER_TOKEN", "SOULSHOUSE_BEARER_TOKEN", "SOULSHOUSE_APP_URL",
    "SOULSHOUSE_ACTIVITY_ORIGIN", "HELIXKIT_BEARER_TOKEN", "HELIXKIT_APP_URL",
    "SOULSHOUSE_HOME_PROFILE", "SOULSHOUSE_PORTABLE_HOME_ID", "AGENT_REPO_PATH",
    "SOULSHOUSE_REQUIRE_HOUSE_TRUST", "TZ",
})
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
    _require(isinstance(image, str) and IMAGE_RE.match(image), "image must be pinned by sha256 digest")
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
    auth = payload.get("registry_auth")
    if auth is not None:
        # A pull-only credential for exactly the image's registry, used for
        # one pull and never written to Docker's global config.
        _require(isinstance(auth, dict) and set(auth) == {"registry", "username", "password"}, "bad registry_auth")
        _require(auth["registry"] == image.split("/", 1)[0], "registry_auth must be for the image's registry")
        for field in ("username", "password"):
            _require(isinstance(auth[field], str) and auth[field] and "\n" not in auth[field], f"bad registry_auth {field}")
    return {"container_name": name, "image": image, "memory_mb": memory, "cpu_shares": shares, "env": dict(env),
            "registry_auth": auth}


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


def _docker(argv, timeout=120, env=None):
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                                   env=None if env is None else {**os.environ, **env})
    except (OSError, subprocess.SubprocessError) as error:
        return False, str(error)
    return completed.returncode == 0, (completed.stdout if completed.returncode == 0 else completed.stderr).strip()


def _http(method, url, token, body=None, ledger_id=None, timeout=10):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", "application/json")
    if ledger_id:
        request.add_header("X-Resident-Ledger-ID", ledger_id)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
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
    """Carries out the five commands. Docker and HTTP are injected so tests
    can see exactly what would run."""

    def __init__(self, state_dir, docker=_docker, http=_http, sleep=time.sleep):
        self.state_dir = state_dir
        self.docker = docker
        self.http = http
        self.sleep = sleep

    # Secrets for a resident live only in its root-owned env file.
    def _env_path(self, name):
        return os.path.join(self.state_dir, "residents", f"{name}.env")

    def _spec_path(self, name):
        return os.path.join(self.state_dir, "residents", f"{name}.json")

    def _write_private(self, path, text):
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        os.rename(tmp, path)

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
        public_spec["env_keys"] = sorted(spec["env"])
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

    def _pull(self, spec):
        auth = spec["registry_auth"]
        if auth is None:
            ok, error = self.docker(["docker", "pull", spec["image"]], timeout=900)
        else:
            config_dir = tempfile.mkdtemp(prefix="pull-", dir=self.state_dir)
            try:
                token = base64.b64encode(f"{auth['username']}:{auth['password']}".encode()).decode("ascii")
                self._write_private(os.path.join(config_dir, "config.json"),
                                    json.dumps({"auths": {auth["registry"]: {"auth": token}}}))
                ok, error = self.docker(["docker", "pull", spec["image"]], timeout=900,
                                        env={"DOCKER_CONFIG": config_dir})
            finally:
                shutil.rmtree(config_dir, ignore_errors=True)
        if not ok:
            raise CommandFailed(f"could not pull image: {error}")

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
            result = {"outcome": "done", "result": getattr(host, command["kind"])(command["payload"])}
        except BadCommand as error:
            result = {"outcome": "refused", "error": str(error)}
        except CommandFailed as error:
            result = {"outcome": "failed", "error": str(error)}
        except Exception as error:  # the effect may or may not have happened
            result = {"outcome": "unknown", "error": f"{type(error).__name__}: {error}"}
    state.record(command["id"], command["generation"], result)
    return command["id"], result


def poll_command_once(config, key, state, host, opener=urllib.request.urlopen):
    """One long-poll. Returns True when a command was handled."""
    status, body = post(config["rails_url"], COMMAND_NEXT_PATH, {}, key, config["runner_id"], opener=opener,
                        timeout=COMMAND_POLL_TIMEOUT_SECONDS + 10)
    if status != 200 or not isinstance(body.get("command"), dict):
        return False
    command_id, result = execute_command(body["command"], state, host)
    if command_id is None or not COMMAND_ID_RE.match(command_id):
        return True
    post(config["rails_url"], COMMAND_RESULT_PATH.format(id=command_id), result, key, config["runner_id"], opener=opener)
    return True


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
        # Heartbeats keep their cadence; between them the runner long-polls
        # for commands. A poll that returns nothing has already waited.
        state = CommandState(state_dir)
        host = ResidentHost(state_dir, sleep=sleep)
        last_beat = None
        while max_heartbeats is None or sent < max_heartbeats:
            if last_beat is None or clock() - last_beat >= HEARTBEAT_SECONDS:
                heartbeat(config, key, facts(config.get("runtime_image")))
                sent += 1
                last_beat = clock()
            try:
                handled = poll(config, key, state, host)
            except Exception as error:  # a broken poll must not stop heartbeats
                print(f"command poll failed: {error}", file=sys.stderr)
                handled = False
            if not handled:
                sleep(5)
        return 0
    while max_heartbeats is None or sent < max_heartbeats:
        heartbeat(config, key, facts(config.get("runtime_image")))
        sent += 1
        sleep(HEARTBEAT_SECONDS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
