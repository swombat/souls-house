"""Bounded public activity projection. Never forward raw Chaos JSONL."""
import collections
import datetime
import json
import logging
import os
import random
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Reporter:
    CATEGORIES = {
        "command_execution": "command", "file_change": "files",
        "mcp_tool_call": "tool", "web_search": "search",
        "collab_tool_call": "delegation",
    }

    def __init__(self, config, app_url, provider, auth_mode):
        origin = urllib.parse.urlsplit(app_url or "")
        run_id = str(uuid.UUID(config["run_id"]))
        path = f"/api/v1/runtime_runs/{run_id}/events"
        if config.get("path") != path or origin.scheme not in ("http", "https") or not origin.netloc:
            raise ValueError("Invalid reporting destination")
        if origin.username or origin.password or origin.query or origin.fragment:
            raise ValueError("Invalid reporting origin")
        if origin.scheme == "http" and origin.hostname not in ("localhost", "127.0.0.1", "::1", "host.docker.internal"):
            raise ValueError("Reporting requires HTTPS outside local development")
        # The origin is trusted deployment configuration, never payload input.
        self.url = f"{origin.scheme}://{origin.netloc}{path}"
        self.token = config["token"]
        self.run_id = run_id
        self.deadline = datetime.datetime.fromisoformat(config["deadline"]).timestamp()
        self.share = config.get("share_narration") is True
        self.capability = "unknown" if provider in ("openai", "openai-codex") else "unsupported"
        self.operations = {}
        self.attempt_id = None
        self.number = 0
        self.seq = 0
        self.queue = collections.deque()
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.closed = False
        self.disabled = False
        self.dropped = 0
        self.thread = threading.Thread(target=self._send_loop, daemon=True)
        self.thread.start()

    def emit(self, kind, data=None):
        with self.lock:
            if self.disabled or not self.attempt_id:
                return
            self.seq += 1
            if kind == "heartbeat":
                data = {"operations": list(self.operations.values()), "detail_dropped": self.dropped}
            event = {"seq": self.seq, "type": kind, "data": data or {}}
            packet = {
                "schema_version": 1, "batch_id": str(uuid.uuid4()),
                "run_id": self.run_id, "attempt_id": self.attempt_id,
                "attempt_number": self.number, "events": [event],
            }
            encoded = json.dumps(packet).encode()
            if len(encoded) > 64 * 1024:
                self.dropped += 1
                return
            # Keep control events; detail is allowed to be incomplete.
            while sum(len(item[0]) for item in self.queue) + len(encoded) > 1024 * 1024:
                removable = next((i for i, item in enumerate(self.queue)
                                  if item[1] not in ("attempt.started", "fallback", "supervisor.finished")), None)
                if removable is None:
                    self.dropped += 1
                    return
                del self.queue[removable]
                self.dropped += 1
            self.queue.append((encoded, kind))
        self.wake.set()

    def begin_attempt(self):
        with self.lock:
            if self.attempt_id:
                self.emit("fallback")
            self.attempt_id = str(uuid.uuid4())
            self.number += 1
            self.seq = 0
            self.operations = {}
            self.emit("attempt.started", {"narration_capability": self.capability})

    def project(self, event):
        kind = event.get("type")
        if kind == "turn.started":
            self.emit("turn.started")
        elif kind in ("turn.completed", "turn.failed"):
            self.emit("turn.finished")
        elif kind in ("item.started", "item.updated", "item.completed"):
            item = event.get("item") or {}
            category = self.CATEGORIES.get(item.get("type"))
            if category:
                operation = {
                    "operation_id": str(item.get("id", "unknown")).encode()[:200].decode(errors="ignore"),
                    "category": category,
                    "outcome": ("failed" if item.get("status") in ("failed", "declined") else "completed") if kind == "item.completed" else None,
                }
                with self.lock:
                    self.operations.pop(operation["operation_id"], None)
                    if kind != "item.completed" and len(self.operations) < 64:
                        self.operations[operation["operation_id"]] = operation
                self.emit("tool.finished" if kind == "item.completed" else "tool.started", operation)
            elif item.get("type") == "agent_message" and kind == "item.completed":
                if item.get("phase") == "commentary" and item.get("canonical") is not False:
                    self.capability = "supported"
                    if self.share:
                        self.emit("commentary.completed", {"text": self._text(item.get("text", ""))})
            elif item.get("type") == "todo_list" and self.share:
                self.emit("plan.updated", {"steps": [
                    {"text": self._text(step.get("text", "")),
                     "status": "completed" if step.get("completed") else "pending"}
                    for step in item.get("items", [])[:100] if isinstance(step, dict)
                ]})

    @staticmethod
    def _text(value):
        return str(value).encode()[:4096].decode("utf-8", errors="ignore")

    def run(self, args, prompt, env, timeout):
        self.begin_attempt()
        reader_attempt_id = self.attempt_id
        env = env.copy()
        env["SOULSHOUSE_RUNTIME_RUN_ID"] = self.run_id
        env["SOULSHOUSE_RUNTIME_CHAT_ID"] = getattr(self, "conversation_id", "") or ""
        for key in list(env):
            if "ACTIVITY_TOKEN" in key:
                env.pop(key)
        timeout = max(0.1, min(timeout, self.deadline - time.time()))
        proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, start_new_session=True)
        retained = collections.deque()
        retained_size = 0
        process_started = b""
        stderr = bytearray()

        def read_stdout():
            nonlocal retained_size, process_started
            while True:
                line = proc.stdout.readline(1024 * 1024 + 1)
                if not line:
                    break
                if len(line) > 1024 * 1024:
                    while line and not line.endswith(b"\n"):
                        line = proc.stdout.readline(1024 * 1024)
                    with self.lock:
                        self.dropped += 1
                    continue
                try:
                    event = json.loads(line)
                    if not isinstance(event, dict):
                        continue
                    with self.lock:
                        if self.attempt_id == reader_attempt_id:
                            self.project(event)
                    if event.get("type") == "process.started":
                        process_started = line
                        continue
                    # Retain only what the existing terminal/session parser uses,
                    # bounded to 1MiB. Private tool/reasoning payloads are discarded.
                    if event.get("type") in ("process.started", "turn.completed", "invocation.completed", "error", "turn.failed") or (
                            event.get("type") == "item.completed" and (event.get("item") or {}).get("type") == "agent_message"):
                        while retained and retained_size + len(line) > 1024 * 1024:
                            retained_size -= len(retained.popleft())
                        retained.append(line)
                        retained_size += len(line)
                except (ValueError, TypeError, AttributeError):
                    continue

        def read_stderr():
            while chunk := proc.stderr.read(4096):
                stderr.extend(chunk)
                del stderr[:-4000]

        def write_prompt():
            try:
                proc.stdin.write(prompt.encode())
                proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass

        readers = [threading.Thread(target=fn, daemon=True) for fn in (read_stdout, read_stderr, write_prompt)]
        for thread in readers:
            thread.start()
        expires = time.monotonic() + timeout
        try:
            while proc.poll() is None:
                remaining = expires - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                try:
                    proc.wait(timeout=min(10, remaining))
                except subprocess.TimeoutExpired:
                    self.emit("heartbeat")
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
            raise
        finally:
            # Also prevent background descendants retaining pipes after the
            # supervised root exits. Only this invocation's process group.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for thread in readers:
                thread.join(timeout=1)
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                pipe.close()
        return subprocess.CompletedProcess(args, proc.returncode,
                                           (process_started + b"".join(retained)).decode(errors="replace"),
                                           stderr.decode(errors="replace"))

    def finish(self, response):
        body_response, status = response if isinstance(response, tuple) else (response, 200)
        body = body_response.get_json() if hasattr(body_response, "get_json") else body_response
        body = body if isinstance(body, dict) else {}
        outcome = "timed_out" if status == 504 else ("failed" if status >= 400 else "completed")
        if not self.attempt_id:
            self.begin_attempt()
        with self.lock:
            self.operations = {}
        self.emit("supervisor.finished", {
            "outcome": outcome, "telemetry": self._safe_telemetry(body.get("telemetry")),
            "runtime_status": body.get("status"), "returncode": body.get("returncode"),
            "detail_dropped": self.dropped,
        })
        self.closed = True
        self.wake.set()
        self.thread.join(timeout=2)
        self.disabled = True

    @staticmethod
    def _safe_telemetry(source):
        if not isinstance(source, dict):
            return {}
        keys = {
            "runtime": ("chaos_version", "provider", "model", "cache_ttl"),
            "session": ("chaos_process_id", "prior_chaos_process_id", "outcome",
                        "persistent_requested", "mapping_found", "resume_attempted",
                        "trigger_sequence", "session_age_seconds"),
            "prompt": ("mode", "full_prompt_bytes", "delta_prompt_bytes", "selected_prompt_bytes"),
            "usage": ("input_tokens", "uncached_input_tokens", "cache_creation_input_tokens",
                      "cache_read_input_tokens", "cached_input_tokens", "output_tokens",
                      "reasoning_output_tokens", "provider_request_count", "scope", "complete"),
        }
        safe = {"schema_version": 1}
        for section, names in keys.items():
            values = source.get(section)
            if isinstance(values, dict):
                safe[section] = {key: value for key, value in values.items() if key in names and (
                    isinstance(value, (bool, int)) or isinstance(value, str) and len(value.encode()) <= 200)}
        return safe

    def _send_loop(self):
        opener = urllib.request.build_opener(NoRedirect)
        backoff = 0.5
        pending = None
        retry_batches = collections.deque()
        while not self.disabled:
            with self.lock:
                if pending is None and retry_batches:
                    pending = retry_batches.popleft()
                if pending is None and self.queue:
                    first = json.loads(self.queue[0][0])
                    entries = []
                    events = []
                    encoded = None
                    for entry in self.queue:
                        candidate = json.loads(entry[0])
                        if candidate["attempt_id"] != first["attempt_id"] or len(events) >= 50:
                            break
                        combined = {**first, "events": events + candidate["events"]}
                        proposed = json.dumps(combined).encode()
                        if len(proposed) > 64 * 1024:
                            break
                        encoded = proposed
                        events = combined["events"]
                        entries.append(entry)
                    pending = (encoded, entries)
            if pending is None:
                if self.closed:
                    return
                self.wake.wait(0.5)
                self.wake.clear()
                continue
            try:
                req = urllib.request.Request(self.url, data=pending[0], method="POST",
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.token}"})
                with opener.open(req, timeout=5) as response:
                    ack = json.loads(response.read(8192))
                if ack.get("share_narration") is False:
                    self.share = False
                    with self.lock:
                        self.queue = collections.deque(item for item in self.queue
                            if item[1] not in ("commentary.completed", "plan.updated"))
                        retry_batches = collections.deque(batch for batch in retry_batches
                            if batch[1][0][1] not in ("commentary.completed", "plan.updated"))
                with self.lock:
                    acknowledged = {id(entry) for entry in pending[1]}
                    self.queue = collections.deque(entry for entry in self.queue if id(entry) not in acknowledged)
                pending = None
                backoff = 0.5
            except urllib.error.HTTPError as error:
                if error.code == 422:
                    if len(pending[1]) > 1:
                        # Isolate bad detail without losing registration or a
                        # valid terminal outcome in the same atomic batch.
                        retry_batches.extend((entry[0], [entry]) for entry in pending[1])
                    elif pending[1][0][1] in ("attempt.started", "fallback", "supervisor.finished"):
                        logging.getLogger(__name__).warning("Activity control event rejected; reporting stopped")
                        self.disabled = True
                        return
                    else:
                        with self.lock:
                            rejected = {id(entry) for entry in pending[1]}
                            self.queue = collections.deque(entry for entry in self.queue if id(entry) not in rejected)
                            self.dropped += 1
                        if pending[1][0][1] != "heartbeat":
                            self.emit("heartbeat")
                    pending = None
                    continue
                if error.code != 429 and error.code < 500:
                    logging.getLogger(__name__).warning("Activity reporting stopped (HTTP %s)", error.code)
                    self.disabled = True
                    return
                retry_after = error.headers.get("Retry-After", "")
                delay = min(30, float(retry_after)) if retry_after.isdigit() else backoff
                time.sleep(delay + random.uniform(0, 0.25))
                backoff = min(30, backoff * 2)
            except (OSError, ValueError):
                time.sleep(backoff + random.uniform(0, 0.25))
                backoff = min(30, backoff * 2)
