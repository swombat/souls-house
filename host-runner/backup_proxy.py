"""Bounded VM backups. No cloud credentials or resident network access.

Integration: run_backup(payload, host, signed_request=callback).
host supplies _known_resident(name). Optional docker(argv, timeout=...) returns
(ok, output) and must honour its timeout. BackupFailed.result must be included in failed command
answers, not discarded by the ordinary CommandFailed handler.
An optional host.begin_backup_recovery(name) runs only after accepting the
second safe state inspection, before a pause can happen. Lifecycle owns its
marker. A safe answer requires both unpaused and verified tools_stopped.

signed_request(method, fullpath, body, timeout=..., request_headers=None)
-> (status, headers, bytes). Only validated single Range headers are forwarded;
like Accept, Range is not in the runner's signature string. Response ranges
are checked independently before any bytes reach restic.
must sign the FULL path, including the sole permitted query ?create=true.
make_signed_request provides a no-redirect, bounded binary implementation.
Incoming chunked POSTs are decoded under body/frame/deadline caps before signing
the decoded bytes. Restic's open ranges are resolved by signed HEAD, then sent
as closed intervals; no range is silently dropped.
"""

import base64
import hashlib
import hmac
import http.client
import http.server
import json
import os
import re
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse

from souls_house_runner import BadCommand, CommandFailed, NAME_RE, validate_origin, volume_name

BACKUP_PATH = "/api/v1/host_runner/backup"
MAX_BODY_BYTES = 32 * 1024 * 1024
MAX_CHECKPOINT_BYTES = 50_000_000
MAX_REQUESTS = 4096
MAX_CHUNK_FRAMES = 4096
REQUEST_SECONDS = 30
IO_SECONDS = 5
RESTIC_IMAGE = "restic/restic@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76"
# Published 0.18.1 OCI index, verified 2026-10-09 against Docker Hub's
# Docker-Content-Digest and SHA256 of the anonymously fetched manifest bytes.
CLEANUP_SECONDS = 20
UNPAUSE_SECONDS = 10
MAX_DEADLINE_SECONDS = 900
BACKUP_TOOL_FILTER = "name=^/souls-house-backup-[0-9a-f]{24}$"
OUTPUT_BYTES = 128 * 1024
HEX_RE = re.compile(r"[0-9a-f]{64}\Z")
UUID_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
ROLES = ("identity", "chaos", "repo", "work")
TYPES = ("keys", "locks", "snapshots", "index", "data")


class BackupFailed(CommandFailed):
    def __init__(self, message, result):
        super().__init__(message)
        self.result = result


class BodyTooLarge(BadCommand):
    pass


def read_request_body(stream, connection, method, headers, deadline):
    """Decode one bounded body, never forwarding HTTP framing to the house."""
    lengths = headers.get_all("Content-Length", [])
    transfers = headers.get_all("Transfer-Encoding", [])
    if headers.get("Expect") is not None or headers.get("Trailer") is not None:
        raise BadCommand("unsupported request framing")
    if (len(lengths) > 1 or len(transfers) > 1 or (lengths and transfers) or
            (lengths and not re.fullmatch(r"[0-9]{1,10}", lengths[0]))):
        raise BadCommand("ambiguous request framing")
    if transfers and (method != "POST" or transfers[0].lower() != "chunked"):
        raise BadCommand("unsupported transfer encoding")
    if method == "POST" and not lengths and not transfers:
        raise BadCommand("request length required")

    def set_timeout():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("backup request body deadline")
        connection.settimeout(min(IO_SECONDS, remaining))

    def read_exact(length):
        chunks = []
        while length:
            set_timeout()
            chunk = stream.read1(min(64 * 1024, length))
            if not chunk:
                raise BadCommand("incomplete body")
            chunks.append(chunk)
            length -= len(chunk)
        return b"".join(chunks)

    if not transfers:
        length = int(lengths[0]) if lengths else 0
        if length > MAX_BODY_BYTES:
            raise BodyTooLarge("body too large")
        if method != "POST" and length:
            raise BadCommand("unexpected body")
        return read_exact(length)

    chunks, total = [], 0
    for _ in range(MAX_CHUNK_FRAMES):
        set_timeout()
        # No chunk extensions, whitespace, signs, bare LF, or unbounded lines.
        line = stream.readline(12)
        if not re.fullmatch(rb"[0-9a-fA-F]{1,8}\r\n", line):
            raise BadCommand("invalid chunk header")
        size = int(line[:-2], 16)
        if size == 0:
            if read_exact(2) != b"\r\n":
                raise BadCommand("trailers are not accepted")
            return b"".join(chunks)
        total += size
        if total > MAX_BODY_BYTES:
            raise BodyTooLarge("body too large")
        chunks.append(read_exact(size))
        if read_exact(2) != b"\r\n":
            raise BadCommand("invalid chunk terminator")
    raise BadCommand("chunk frame budget exceeded")


def _require(condition, message):
    if not condition:
        raise BadCommand(message)


def rest_path(method, target):
    """Return the exact house fullpath, or refuse non-restic wire grammar."""
    if method == "POST" and target == "/?create=true":
        return BACKUP_PATH + target
    if not isinstance(target, str) or "?" in target or "#" in target:
        raise BadCommand("bad backup path")
    if target == "/config" and method in ("GET", "HEAD", "POST"):
        return BACKUP_PATH + target
    if method == "GET" and target in tuple(f"/{kind}/" for kind in TYPES):
        return BACKUP_PATH + target
    match = re.fullmatch(r"/(keys|locks|snapshots|index|data)/([0-9a-f]{64})", target)
    if match and (method in ("GET", "HEAD", "POST") or
                  (method == "DELETE" and match[1] == "locks")):
        return BACKUP_PATH + target
    raise BadCommand("bad backup method or path")


def validate_range(method, target, value):
    """Accept one bounded, complete byte interval on an object GET only."""
    if value is None:
        return None
    if method != "GET" or target.endswith("/") or not isinstance(value, str):
        raise BadCommand("Range requires an object GET")
    match = re.fullmatch(r"bytes=([0-9]{1,19})-([0-9]{1,19})", value)
    if not match:
        raise BadCommand("invalid Range")
    start, end = int(match[1]), int(match[2])
    if start > end or end > 2**63 - 1 or end - start + 1 > MAX_BODY_BYTES:
        raise BadCommand("Range exceeds bounds")
    return start, end


def validate_range_response(bounds, status, headers, body):
    if bounds is None:
        if status == 206:
            raise ValueError("unsolicited partial response")
        return None
    content_range = headers.get("Content-Range")
    match = re.fullmatch(r"bytes ([0-9]{1,19})-([0-9]{1,19})/([0-9]{1,19})",
                        content_range if isinstance(content_range, str) else "")
    if status != 206 or not match:
        raise ValueError("Range requires a valid 206 Content-Range")
    start, end, total = map(int, match.groups())
    if (start, end) != bounds or not end < total <= 2**63 - 1 or len(body) != end - start + 1:
        raise ValueError("response does not match requested Range")
    length = headers.get("Content-Length")
    if length is not None and (not re.fullmatch(r"[0-9]{1,10}", str(length)) or int(length) != len(body)):
        raise ValueError("Range response length mismatch")
    return content_range


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _bad_constant(value):
    raise ValueError("non-finite JSON number")


def validate_payload(payload):
    fields = {
        "container_name", "agent_uuid", "agent_slug", "restic_password", "deadline_seconds",
        "checkpoint_json", "checkpoint_digest", "checkpoint_file_sha256",
    }
    _require(isinstance(payload, dict) and set(payload) == fields, "bad backup payload fields")
    for key, pattern in (("container_name", NAME_RE), ("agent_slug", NAME_RE),
                         ("agent_uuid", UUID_RE), ("checkpoint_file_sha256", HEX_RE)):
        value = payload[key]
        _require(isinstance(value, str) and pattern.fullmatch(value), f"bad {key}")
    password = payload["restic_password"]
    _require(isinstance(password, str) and 1 <= len(password) <= 4096 and
             not any(char in password for char in "\r\n\0"), "bad restic_password")
    deadline = payload["deadline_seconds"]
    _require(type(deadline) is int and CLEANUP_SECONDS < deadline <= MAX_DEADLINE_SECONDS, "bad backup deadline")
    digest = payload["checkpoint_digest"]
    _require(digest is None or (isinstance(digest, str) and HEX_RE.fullmatch(digest)),
             "bad checkpoint_digest")
    raw = payload["checkpoint_json"]
    _require(isinstance(raw, str) and len(raw) <= MAX_CHECKPOINT_BYTES, "bad checkpoint_json")
    try:
        data = raw.encode("utf-8")
        _require(len(data) <= MAX_CHECKPOINT_BYTES, "checkpoint too large")
        envelope = json.loads(raw, object_pairs_hook=_unique_object, parse_constant=_bad_constant)
    except (ValueError, RecursionError, UnicodeError):
        raise BadCommand("invalid checkpoint JSON") from None
    _require(hmac.compare_digest(hashlib.sha256(data).hexdigest(), payload["checkpoint_file_sha256"]),
             "checkpoint file SHA mismatch")
    if envelope is None:
        _require(raw == "null" and digest is None, "bad null checkpoint")
        return dict(payload), data
    _require(isinstance(envelope, dict) and set(envelope) == {"payload", "sha256"},
             "bad checkpoint envelope")
    graph = envelope["payload"]
    _require(envelope["sha256"] == payload["checkpoint_digest"], "checkpoint digest mismatch")
    _require(isinstance(graph, dict) and type(graph.get("version")) is int and graph["version"] == 1 and
             graph.get("resident_uuid") == payload["agent_uuid"] and
             isinstance(graph.get("nodes"), list) and isinstance(graph.get("edges"), list) and
             isinstance(graph.get("settings"), dict), "checkpoint belongs to another resident or schema")
    # Do not reserialize Ruby JSON here: float spelling and escaping differ.
    # The house independently verifies the payload digest when dumping this
    # exact file. Both the envelope digest and whole-file SHA are reported.
    return dict(payload), data


def make_signed_request(config, key, signed_headers):
    """Create a binary transport, bypassing redirects and ambient HTTP proxies."""
    origin = urllib.parse.urlsplit(validate_origin(config.get("rails_url")))

    def request(method, fullpath, body, timeout=REQUEST_SECONDS, request_headers=None):
        # Validation here protects callers other than the loopback server too.
        target = fullpath.removeprefix(BACKUP_PATH)
        if fullpath != rest_path(method, target) or len(body) > MAX_BODY_BYTES:
            raise BadCommand("bad signed backup request")
        extra = {} if request_headers is None else request_headers
        if not isinstance(extra, dict) or set(extra) - {"Range"}:
            raise BadCommand("unsupported backup request headers")
        if "Range" in extra and not isinstance(extra["Range"], str):
            raise BadCommand("invalid Range header")
        bounds = validate_range(method, target, extra.get("Range"))
        ends = time.monotonic() + timeout
        headers = signed_headers(key, method, fullpath, body, config["runner_id"])
        headers["Content-Type"] = "application/octet-stream"
        headers["Accept"] = "application/vnd.x.restic.rest.v2"
        headers.update(extra)
        connection = http.client.HTTPSConnection(origin.hostname, origin.port or 443,
                                                  timeout=min(IO_SECONDS, timeout))
        timer = None
        try:
            connection.connect()
            transport_socket = connection.sock

            def expire():
                try:
                    transport_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

            # Bound request/response headers too, including a remote slow drip.
            timer = threading.Timer(max(0.001, ends - time.monotonic()), expire)
            timer.daemon = True
            timer.start()
            connection.request(method, fullpath, body=body, headers=headers)
            response = connection.getresponse()
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdecimal() or int(length) > MAX_BODY_BYTES):
                raise ValueError("house response too large")
            chunks, size = [], 0
            while True:
                remaining = ends - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("backup request deadline")
                if connection.sock is not None:
                    connection.sock.settimeout(min(IO_SECONDS, remaining))
                chunk = response.read1(min(64 * 1024, MAX_BODY_BYTES + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_BODY_BYTES:
                    raise ValueError("house response too large")
                chunks.append(chunk)
            # http.client never follows 3xx. Do not expose Location locally.
            response_headers = {"Content-Type": response.getheader("Content-Type", "application/octet-stream")}
            if length is not None:
                response_headers["Content-Length"] = length
            content_range = response.getheader("Content-Range")
            if content_range is not None:
                response_headers["Content-Range"] = content_range
            data = b"".join(chunks)
            validate_range_response(bounds, response.status, response_headers, data)
            return response.status, response_headers, data
        finally:
            if timer is not None:
                timer.cancel()
            connection.close()
    return request


class _LoopbackServer(http.server.HTTPServer):
    # Serial handling means at most one request/body is in memory. The queue
    # and accept/read timeouts are bounded; no thread-per-untrusted-connection.
    request_queue_size = 2
    active_connection = None
    connection_deadline = 0

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(IO_SECONDS)
        self.connection_deadline = min(self.deadline, time.monotonic() + REQUEST_SECONDS)
        self.active_connection = connection
        return connection, address

    def shutdown_request(self, request):
        self.active_connection = None
        super().shutdown_request(request)

    def handle_error(self, request, client_address):
        pass  # Disconnected clients are not an operator error or a secret log.


class BackupProxy:
    def __init__(self, signed_request, deadline, max_requests=MAX_REQUESTS):
        self.signed_request = signed_request
        self.deadline = deadline
        self.max_requests = max_requests
        self.requests = 0
        # Bound even a DNS lookup / injected transport that does not return.
        # Timed-out workers retain their slot until they actually exit, so no
        # series of timeouts can create an unbounded set of background threads.
        self.request_slots = threading.BoundedSemaphore(2)
        self.token = secrets.token_hex(32)
        self.authorization = "Basic " + base64.b64encode(f"backup:{self.token}".encode()).decode()
        proxy = self

        class Handler(http.server.BaseHTTPRequestHandler):
            # One request per connection: no ambiguous pipelining or chunking.
            protocol_version = "HTTP/1.0"

            def log_message(self, *args):
                pass  # Never log the URL, Basic token, or binary contents.

            def answer(self, status, body=b"", content_type="application/octet-stream", head_length=None,
                       content_range=None):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(head_length if head_length is not None else len(body)))
                self.send_header("Connection", "close")
                if content_range is not None:
                    self.send_header("Content-Range", content_range)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def relay(self):
                proxy.requests += 1
                ends = min(proxy.deadline, time.monotonic() + REQUEST_SECONDS)
                if proxy.requests > proxy.max_requests or ends <= time.monotonic():
                    self.answer(429)
                    return
                auth = self.headers.get_all("Authorization", [])
                if len(auth) != 1 or not hmac.compare_digest(auth[0].encode("utf-8"), proxy.authorization.encode()):
                    self.answer(401)
                    return
                try:
                    remote_path = rest_path(self.command, self.path)
                    ranges = self.headers.get_all("Range", [])
                    if len(ranges) > 1:
                        raise BadCommand("multiple Range headers")
                    range_value = ranges[0] if ranges else None
                    decoded_body = read_request_body(self.rfile, self.connection, self.command, self.headers, ends)
                    range_value = proxy.closed_range(self.command, remote_path, range_value, ends)
                    bounds = validate_range(self.command, self.path, range_value)
                    seconds = ends - time.monotonic()
                    if seconds <= 0:
                        raise TimeoutError()
                    status, headers, body = proxy.request(
                        self.command, remote_path, decoded_body, timeout=seconds,
                        request_headers={"Range": range_value} if ranges else None)
                    if not isinstance(body, bytes) or len(body) > MAX_BODY_BYTES:
                        raise ValueError("response too large")
                    content_range = validate_range_response(bounds, status, headers, body)
                    if 300 <= status < 400:
                        self.answer(502)  # Never redirect restic to another host.
                    else:
                        content_type = headers.get("Content-Type", "application/octet-stream")
                        if not isinstance(content_type, str) or "\r" in content_type or "\n" in content_type:
                            raise ValueError("bad response content type")
                        head_length = None
                        if self.command == "HEAD" and "Content-Length" in headers:
                            length = str(headers["Content-Length"])
                            if not re.fullmatch(r"[0-9]{1,10}", length) or int(length) > MAX_BODY_BYTES:
                                raise ValueError("bad HEAD response size")
                            head_length = int(length)
                        self.answer(status, body, content_type, head_length=head_length,
                                    content_range=content_range)
                except BodyTooLarge:
                    self.answer(413)
                except BadCommand:
                    self.answer(400)
                except (OSError, ValueError, http.client.HTTPException):
                    self.answer(502)

            do_GET = relay
            do_HEAD = relay
            do_POST = relay
            do_DELETE = relay
            do_PUT = relay
            do_PATCH = relay
            do_OPTIONS = relay
            do_TRACE = relay

        self.server = _LoopbackServer(("127.0.0.1", 0), Handler)
        self.server.deadline = deadline
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.stop = threading.Event()

        def watch():
            # Socket timeouts alone bound inactivity, not a slow drip of
            # request headers. One watchdog bounds total connection lifetime.
            while not self.stop.wait(0.05):
                connection = self.server.active_connection
                if connection is not None and time.monotonic() >= self.server.connection_deadline:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        self.watchdog = threading.Thread(target=watch, daemon=True)

    @property
    def repository(self):
        return f"rest:http://backup:{self.token}@127.0.0.1:{self.server.server_port}/"

    def closed_range(self, method, path, value, deadline):
        """Real restic uses bytes=N-. Resolve via signed HEAD, never drop it.

        Append-only objects cannot change between HEAD and GET. Only a bounded
        closed interval is sent to the house; its 206 is still checked exactly.
        """
        match = re.fullmatch(r"bytes=([0-9]{1,19})-", value or "")
        if not match:
            validate_range(method, path, value)
            return value
        start = int(match[1])
        if method != "GET" or path.endswith("/") or start > 2**63 - 1:
            raise BadCommand("invalid open Range")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Range HEAD deadline")
        status, headers, body = self.request("HEAD", path, b"", timeout=remaining)
        length = str(headers.get("Content-Length", ""))
        if status != 200 or body or not re.fullmatch(r"[0-9]{1,10}", length):
            raise ValueError("cannot bound open Range")
        size = int(length)
        if not start < size <= MAX_BODY_BYTES:
            raise ValueError("open Range exceeds object bounds")
        return f"bytes={start}-{size - 1}"

    def request(self, method, path, body, timeout, request_headers=None):
        if not self.request_slots.acquire(blocking=False):
            return 429, {}, b""
        outcome = {}

        def send():
            try:
                kwargs = {"timeout": timeout}
                if request_headers:
                    kwargs["request_headers"] = request_headers
                outcome["response"] = self.signed_request(method, path, body, **kwargs)
            except Exception as error:
                outcome["error"] = error
            finally:
                self.request_slots.release()

        worker = threading.Thread(target=send, daemon=True)
        worker.start()
        worker.join(timeout=max(0.001, timeout))
        if worker.is_alive():
            raise TimeoutError("signed backup request deadline")
        if "error" in outcome:
            raise outcome["error"]
        return outcome["response"]

    def __enter__(self):
        self.thread.start()
        self.watchdog.start()
        return self

    def __exit__(self, *args):
        connection = self.server.active_connection
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=IO_SECONDS + REQUEST_SECONDS)
        self.stop.set()
        self.watchdog.join(timeout=1)


def bounded_docker(argv, timeout=120):
    """Keep only output tails and kill/reap the Docker CLI on deadline.

    run_backup additionally removes its named container in finally: killing a
    docker run client alone does not stop a daemon-side backup container.
    """
    try:
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError:
        return False, "could not launch Docker"
    tails = [bytearray(), bytearray()]
    threads = []

    def drain(stream, tail):
        try:
            for chunk in iter(lambda: stream.read(8192), b""):
                tail.extend(chunk)
                del tail[:-OUTPUT_BYTES]
        finally:
            stream.close()

    for stream, tail in zip((process.stdout, process.stderr), tails):
        thread = threading.Thread(target=drain, args=(stream, tail), daemon=True)
        thread.start()
        threads.append(thread)
    timed_out = False
    try:
        process.wait(timeout=max(0.001, timeout))
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
    finally:
        # SIGTERM becomes SystemExit in the runner. Do not block its finally
        # path waiting for a still-running docker client before tools can be
        # removed and the resident resumed.
        if process.poll() is None:
            process.kill()
        process.wait()
        for thread in threads:
            thread.join(timeout=1)
    if timed_out:
        return False, "Docker deadline exceeded"
    return process.returncode == 0, bytes(tails[0 if process.returncode == 0 else 1]).decode("utf-8", "replace").strip()


def _state(docker, name, timeout):
    ok, output = docker(["docker", "inspect", "--format", "{{json .State}}", name], timeout=timeout)
    if not ok:
        raise CommandFailed("cannot inspect resident state")
    try:
        state = json.loads(output)
        if not isinstance(state, dict) or type(state.get("Paused")) is not bool or type(state.get("Running")) is not bool:
            raise ValueError()
        return state
    except (ValueError, TypeError):
        raise CommandFailed("invalid resident state") from None


def restic_argv(spec, repository, env_file, checkpoint_dir, tool_name, command):
    argv = [
        "docker", "run", "--rm", "--pull", "never", "--name", tool_name,
        "--network", "host", "--read-only", "--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH",
        "--security-opt", "no-new-privileges", "--memory", "512m", "--cpus", "1",
        "--pids-limit", "64", "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=64m",
        "--env-file", env_file,
    ]
    for role in ROLES:
        argv += ["--mount", f"type=volume,src={volume_name(spec['container_name'], role)},dst=/data/{role},readonly"]
    argv += ["--mount", f"type=bind,src={checkpoint_dir},dst=/data/memory-graph,readonly",
             RESTIC_IMAGE, "--no-cache", "-o", "rest.connections=1", *command]
    return argv


def restic_config_exists(output):
    """Recognize only pinned restic 0.18.1's whole existing-config diagnostic."""
    return re.fullmatch(
        r"Fatal: create repository at (?P<repository>[^\r\n]+) failed: "
        r"Fatal: unable to open repository at (?P=repository): config file already exists",
        output.strip(),
    ) is not None


def run_backup(payload, host, *, signed_request, docker=None,
               proxy_factory=BackupProxy, clock=time.monotonic):
    """Run under the house's idle admission hold; do not acquire that hold here.

    Validation raises BadCommand. Operational failures raise BackupFailed with
    a structured .result, including whether this command left the home unpaused.
    Work reserves 20 seconds for cleanup. Unpause always gets a fresh ten
    seconds and one retry, even after an overrun: safety beats the work deadline.
    """
    spec, checkpoint = validate_payload(payload)
    deadline_seconds = spec["deadline_seconds"]
    name = spec["container_name"]
    host._known_resident(name)
    docker = docker or bounded_docker
    started = clock()
    ends = started + deadline_seconds
    work_ends = ends - CLEANUP_SECONDS
    result = {
        "container_name": name, "checkpoint_digest": spec["checkpoint_digest"],
        "checkpoint_file_sha256": spec["checkpoint_file_sha256"],
        "snapshot_id": None, "size_bytes": 0, "unpaused": False, "tools_stopped": False, "duration_ms": 0,
    }
    pause_attempted = False
    tools = []
    error = None
    refusal = None

    def remaining():
        seconds = work_ends - clock()
        if seconds <= 0:
            raise CommandFailed("backup deadline exceeded")
        return seconds

    def run(argv):
        return docker(argv, timeout=remaining())

    try:
        state = _state(docker, name, min(10, remaining()))
        if state["Paused"]:
            raise BadCommand("resident is already paused")
        if state.get("Restarting") or state.get("Dead") or not (
            (state["Running"] and state.get("Status") == "running") or
            (not state["Running"] and state.get("Status") in ("exited", "created"))
        ):
            raise BadCommand("resident is neither running nor stopped")
        # Preflight before taking the filesystem hold.
        for role in ROLES:
            ok, _ = run(["docker", "volume", "inspect", volume_name(name, role)])
            if not ok:
                raise CommandFailed(f"missing resident volume {role}")
        ok, _ = run(["docker", "image", "inspect", RESTIC_IMAGE])
        if not ok:
            ok, _ = run(["docker", "pull", RESTIC_IMAGE])
            if not ok:
                raise CommandFailed("could not fetch backup image")
            ok, _ = run(["docker", "image", "inspect", RESTIC_IMAGE])
            if not ok:
                raise CommandFailed("backup image unavailable after pull")
        # Inspect again after any download. Never inherit somebody else's pause.
        state = _state(docker, name, min(10, remaining()))
        if state["Paused"]:
            raise BadCommand("resident is already paused")
        if state.get("Restarting") or state.get("Dead") or not (
            (state["Running"] and state.get("Status") == "running") or
            (not state["Running"] and state.get("Status") in ("created", "exited"))
        ):
            raise CommandFailed("resident state changed before backup")
        begin_recovery = getattr(host, "begin_backup_recovery", None)
        if callable(begin_recovery):
            begin_recovery(name)
        if state["Running"]:
            pause_attempted = True  # even a timeout may have reached Docker
            ok, _ = run(["docker", "pause", name])
            if not ok:
                raise CommandFailed("could not pause resident")
        with tempfile.TemporaryDirectory(prefix="souls-house-backup-") as temp:
            os.chmod(temp, 0o700)
            checkpoint_dir = os.path.join(temp, "checkpoint")
            os.mkdir(checkpoint_dir, 0o700)
            path = os.path.join(checkpoint_dir, "checkpoint.json")
            with open(path, "xb") as handle:
                os.chmod(path, 0o600)
                handle.write(checkpoint)
            env_file = os.path.join(temp, "restic.env")
            with open(env_file, "x", encoding="utf-8") as handle:
                os.chmod(env_file, 0o600)
                handle.write(f"RESTIC_PASSWORD={spec['restic_password']}\n")
            with proxy_factory(signed_request, work_ends) as proxy:
                with open(env_file, "a", encoding="utf-8") as handle:
                    handle.write(f"RESTIC_REPOSITORY={proxy.repository}\n")
                def restic(command):
                    tool = "souls-house-backup-" + secrets.token_hex(12)
                    tools.append(tool)  # remember before launch, including timeouts
                    return run(restic_argv(spec, proxy.repository, env_file, checkpoint_dir, tool, command))

                ok, output = restic(["init"])
                # Pinned restic 0.18.1 reports an existing config after HEAD 200.
                # Match its whole diagnostic, not arbitrary "already exists" errors.
                if not ok and not (restic_config_exists(output) or re.search(r"\balready initialized\b", output)):
                    raise CommandFailed("restic init failed")
                remaining()
                ok, output = restic([
                    "backup", "/data", "--exclude-caches",
                    "--tag", f"agent_id={spec['agent_uuid']}",
                    "--tag", f"agent_slug={spec['agent_slug']}",
                    "--tag", "helixkit_volume_set=v1", "--json",
                ])
                if not ok:
                    raise CommandFailed("restic backup failed")
                summaries = []
                for line in output.splitlines():
                    try:
                        entry = json.loads(line)
                        if isinstance(entry, dict) and entry.get("message_type") == "summary":
                            summaries.append(entry)
                    except ValueError:
                        pass
                if len(summaries) != 1:
                    raise CommandFailed("missing restic backup summary")
                summary = summaries[0]
                snapshot_id, size = summary.get("snapshot_id"), summary.get("total_bytes_processed")
                # restic --json emits the full hash, not the human 8-char ID.
                if not isinstance(snapshot_id, str) or not HEX_RE.fullmatch(snapshot_id) or type(size) is not int or size < 0:
                    raise CommandFailed("invalid restic backup summary")
                result.update(snapshot_id=snapshot_id, size_bytes=size)
    except BadCommand as caught:
        refusal = caught
    except Exception as caught:
        # No restic output or password is included in a command answer.
        error = str(caught) if isinstance(caught, CommandFailed) else f"backup failed: {type(caught).__name__}"
    finally:
        # Stop a timed-out daemon-side restic before allowing new resident work.
        # Use one rm invocation so both tool names share the cleanup budget.
        cleanup_ok = True
        if tools:
            try:
                ok, output = docker(["docker", "rm", "-f", *tools], timeout=max(0.001, min(5, ends - clock())))
                # A launch failure can leave no container at all. Other daemon
                # errors are failures, not a silently successful cleanup.
                missing = output.splitlines()
                if not ok and not (missing and all(
                    re.fullmatch(r"Error response from daemon: No such container: souls-house-backup-[0-9a-f]{24}", line)
                    for line in missing
                )):
                    cleanup_ok = False
                    error = error or "backup tool cleanup failed"
            except Exception:
                cleanup_ok = False
                error = error or "backup tool cleanup failed"
        try:
            ok, output = docker(["docker", "ps", "-a", "--filter", BACKUP_TOOL_FILTER,
                                 "--format", "{{.Names}}"], timeout=5)
            result["tools_stopped"] = cleanup_ok and ok and not output.strip()
            if not result["tools_stopped"]:
                error = error or "cannot verify backup tools stopped"
        except Exception:
            error = error or "cannot verify backup tools stopped"
        if pause_attempted and result["tools_stopped"]:
            resumed = False
            for _ in range(2):
                try:
                    ok, _ = docker(["docker", "unpause", name], timeout=UNPAUSE_SECONDS)
                    if ok or not _state(docker, name, 5)["Paused"]:
                        resumed = True
                        break
                except Exception:
                    pass
            if not resumed:
                error = error or "could not unpause resident"
        try:
            final_state = _state(docker, name, 5)
            result["unpaused"] = not final_state["Paused"]
        except Exception:
            error = error or "cannot verify resident ended unpaused"
        result["duration_ms"] = round((clock() - started) * 1000)
    if refusal is not None:
        refusal.result = result
        raise refusal
    if not result["unpaused"]:
        error = error or "resident remains paused"
    if error:
        raise BackupFailed(error, result)
    return result
