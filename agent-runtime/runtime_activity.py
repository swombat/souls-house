"""Bounded public activity projection. Never forward raw Chaos JSONL."""
import collections
import datetime
import json
import logging
import os
from pathlib import Path
import random
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import importlib.util


_preview_spec = importlib.util.spec_from_file_location("command_preview", Path(__file__).with_name("command_preview.py"))
_preview_module = importlib.util.module_from_spec(_preview_spec)
_preview_spec.loader.exec_module(_preview_module)
_silence_spec = importlib.util.spec_from_file_location("silence_nudge", Path(__file__).with_name("silence_nudge.py"))
silence_nudge = importlib.util.module_from_spec(_silence_spec)
_silence_spec.loader.exec_module(silence_nudge)


# The ack carries up to ten room messages (see silence_nudge); Rails bounds
# each one, and this bounds what the shim will read.
ACK_MAX_BYTES = 262_144

# soulshouse-plan keeps its pointers here (under the run's CHAOS_HOME).
PLAN_POINTER_DIR = "house-plans"
PLAN_TASK_STATUSES = frozenset(("pending", "in_progress", "blocked", "completed", "cancelled"))
PLAN_READ_TIMEOUT = 5


def is_work_event(event):
    """True for a Chaos event showing the model did something: any item other
    than an error, or a completed turn. Used to refuse a retry of a run that
    may already have acted (#816); read before events are filtered."""
    if not isinstance(event, dict):
        return False
    if event.get("type") == "turn.completed":
        return True
    item = event.get("item")
    return event.get("type") in ("item.started", "item.updated", "item.completed") \
        and isinstance(item, dict) and item.get("type") != "error"


def command_preview(command, extra_secrets=()):
    secrets = [value for key, value in os.environ.items() if _preview_module.SENSITIVE.search(key)]
    return _preview_module.preview(command, secrets + list(extra_secrets))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Reporter:
    SUBAGENT_STATUSES = frozenset(("pending_init", "running", "interrupted", "completed",
                                  "errored", "shutdown", "not_found"))
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
        self.subagents = {}
        self.attempt_id = None
        self.number = 0
        self.seq = 0
        self.queue = collections.deque()
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.closed = False
        self.disabled = False
        self.dropped = 0
        self.silence = None
        # Set by the trigger shim from the payload: the waking turn was spoken.
        self.voice_mode = False
        # The resident's plan (#864): which Chaos session this run is, the env
        # its chaos ran with, and the last plan sent, so only changes are sent.
        self.process_id = None
        self.plan_env = None
        self.plan_bin = "chaos"
        self.last_plan = None
        self.plan_reading = threading.Lock()
        self.thread = threading.Thread(target=self._send_loop, daemon=True)
        self.thread.start()

    def emit(self, kind, data=None):
        with self.lock:
            if self.disabled or not self.attempt_id:
                return
            self.seq += 1
            if kind == "heartbeat":
                data = {"operations": list(self.operations.values()), "detail_dropped": self.dropped}
                if self.share:
                    data["subagents"] = list(self.subagents.values())
            event = {"seq": self.seq, "type": kind, "data": data or {}}
            packet = {
                "schema_version": 1, "batch_id": str(uuid.uuid4()),
                "run_id": self.run_id, "attempt_id": self.attempt_id,
                "attempt_number": self.number, "events": [event],
            }
            encoded = json.dumps(packet, ensure_ascii=False).encode()
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
            self.subagents = {}
            # Each attempt has its own snapshot; send the plan again.
            self.last_plan = None
            self.emit("attempt.started", {"narration_capability": self.capability})
            self.stream_gap("stream.started")

    def project(self, event):
        kind = event.get("type")
        if kind == "process.started":
            if isinstance(event.get("process_id"), str):
                self.process_id = event["process_id"]
            self.stream_gap("stream.started")
        elif kind == "plan.updated":
            # Chaos's own plan tool committed a change (non-clamped sessions).
            self.send_plan(self.plan_payload(event))
        elif kind == "agent.status_changed":
            self.project_subagent(event)
        elif kind == "turn.started":
            self.emit("turn.started")
            self.poll_plan()
        elif kind in ("turn.completed", "turn.failed"):
            self.emit("turn.finished")
            self.poll_plan()
        elif kind in ("item.started", "item.updated", "item.completed"):
            item = event.get("item") or {}
            category = self.CATEGORIES.get(item.get("type"))
            if category:
                operation = {
                    "operation_id": str(item.get("id", "unknown")).encode()[:200].decode(errors="ignore"),
                    "category": category,
                    "outcome": ("failed" if item.get("status") in ("failed", "declined") else "completed") if kind == "item.completed" else None,
                }
                if category == "command":
                    operation["command_preview"] = command_preview(item.get("command"), [self.token])
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

    def plan_payload(self, plan):
        """Titles and states of a Chaos plan's top-level tasks, nothing else.
        Takes `chaos plan read` output or a Chaos plan.updated event."""
        if not isinstance(plan, dict):
            return None
        head = plan.get("plan") if isinstance(plan.get("plan"), dict) else plan
        tasks = plan.get("tasks")
        if not isinstance(tasks, list):
            return None
        tasks = [task for task in tasks if isinstance(task, dict) and task.get("depth", 0) == 0
                 and task.get("status") in PLAN_TASK_STATUSES]
        if all("position" in task for task in tasks):
            tasks.sort(key=lambda task: task["position"] if isinstance(task["position"], int) else 0)
        return {
            "title": self._text(head.get("title", ""))[:200],
            "status": head.get("status") if head.get("status") in ("active", "completed", "cancelled") else "active",
            "steps": [{"text": self._text(task.get("title", "")), "status": task["status"]} for task in tasks[:100]],
        }

    def send_plan(self, payload):
        if not payload or not self.share:
            return
        with self.lock:
            if payload == self.last_plan:
                return
            self.last_plan = payload
        self.emit("plan.updated", payload)

    def plan_pointer(self):
        """The plan soulshouse-plan left for this run, else for this session.
        A plan that ended is shown only on the run that ended it."""
        env = self.plan_env or {}
        home = Path(env.get("CHAOS_HOME") or Path.home() / ".chaos") / PLAN_POINTER_DIR
        names = [f"run-{self.run_id}.json"]
        if self.process_id and "/" not in self.process_id and not self.process_id.startswith("."):
            names.append(f"thread-{self.process_id}.json")
        for name in names:
            try:
                data = json.loads((home / name).read_text())
            except (OSError, ValueError):
                continue
            if not isinstance(data, dict) or not isinstance(data.get("plan_id"), str):
                continue
            if "ended_run_id" in data and data["ended_run_id"] != self.run_id:
                continue
            return data["plan_id"]
        return None

    def poll_plan(self, wait=False):
        """Read the pointed-to plan with `chaos plan read` and send it if it
        changed. Command-line changes emit nothing on the stream, so this is
        how a clamped resident's ticks reach the card. Never raises."""
        if not self.share or self.plan_env is None:
            return
        plan_id = self.plan_pointer()
        if not plan_id:
            return
        if not self.plan_reading.acquire(blocking=wait):
            return

        def read():
            try:
                proc = subprocess.run([self.plan_bin, "plan", "read", plan_id], capture_output=True,
                                      env=self.plan_env, timeout=PLAN_READ_TIMEOUT, stdin=subprocess.DEVNULL)
                if proc.returncode == 0 and len(proc.stdout) <= 1024 * 1024:
                    self.send_plan(self.plan_payload(json.loads(proc.stdout)))
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
            finally:
                self.plan_reading.release()

        if wait:
            read()
        else:
            threading.Thread(target=read, daemon=True).start()

    def project_subagent(self, event):
        if not self.share:
            return
        if not isinstance(event.get("status"), str) or event["status"] not in self.SUBAGENT_STATUSES:
            self.stream_gap()
            return
        identity = [event.get(key) for key in ("parent_process_id", "child_process_id")]
        if any(not isinstance(value, str) or not value or len(value.encode()) > 200 or
               any(char.isspace() or ord(char) < 33 or ord(char) == 127 for char in value) for value in identity):
            self.stream_gap()
            return
        # IDs are ingestion-only. Rails maps them to run-local ordinals; no tool
        # results, roles, prompts or private error strings enter this projection.
        child = {key: event[key] for key in ("parent_process_id", "child_process_id", "status")}
        previous = self.subagents.get(identity[1], {})
        for key in ("agent_nickname", "model"):
            value = event.get(key, previous.get(key))
            child[key] = ("".join(char for char in value if ord(char) >= 32 and ord(char) != 127)
                          .encode()[:200].decode(errors="ignore")) if isinstance(value, str) else None
        with self.lock:
            if identity[1] in self.subagents or len(self.subagents) < 32:
                self.subagents[identity[1]] = child
            # Even beyond the display cap, ingress sees identity for distinct
            # overflow counting. Queue and server identity limits still apply.
            self.emit("agent.status_changed", child)

    def stream_gap(self, kind="stream.gap"):
        with self.lock:
            for child in self.subagents.values():
                if child["status"] in ("pending_init", "running"):
                    child["status"] = "unknown"
            self.emit(kind)

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
        args = self._arm_silence_clock(args, env)
        self.plan_env = {key: value for key, value in env.items()
                         if key not in ("SOULSHOUSE_STEER_FILE",)}
        self.plan_bin = env.get("SOULSHOUSE_CHAOS_BIN") or (args[0] if args else "chaos")
        proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, start_new_session=True)
        retained = collections.deque()
        retained_size = 0
        process_started = b""
        stderr = bytearray()
        work_seen = False
        gap_seen = False

        def source_gap():
            nonlocal gap_seen
            # Whatever was in a dropped line is unknown, so a retry is unsafe.
            gap_seen = True
            with self.lock:
                if self.attempt_id == reader_attempt_id:
                    self.stream_gap()

        def read_stdout():
            nonlocal retained_size, process_started, work_seen
            while True:
                line = proc.stdout.readline(1024 * 1024 + 1)
                if not line:
                    break
                if len(line) > 1024 * 1024:
                    while line and not line.endswith(b"\n"):
                        line = proc.stdout.readline(1024 * 1024)
                    with self.lock:
                        self.dropped += 1
                        source_gap()
                    continue
                try:
                    event = json.loads(line)
                    if not isinstance(event, dict):
                        source_gap()
                        continue
                    # Before any filtering: a run that acted must not be retried.
                    work_seen = work_seen or is_work_event(event)
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
                    source_gap()
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
        last_heartbeat = time.monotonic()
        try:
            while proc.poll() is None:
                remaining = expires - time.monotonic()
                cancel = getattr(self, "cancel_event", None)
                if remaining <= 0 or (cancel is not None and cancel.is_set()):
                    raise subprocess.TimeoutExpired(args, timeout)
                if self.silence and self.silence.tick(time.time()):
                    logging.getLogger(__name__).info("silence notice written run_id=%s", self.run_id)
                try:
                    proc.wait(timeout=min(.5 if cancel is not None else 5, remaining))
                except subprocess.TimeoutExpired:
                    if time.monotonic() - last_heartbeat >= 10:
                        self.emit("heartbeat")
                        self.poll_plan()
                        last_heartbeat = time.monotonic()
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
            # Keep what Chaos wrote before the deadline (process.started and
            # any turn events) so the timeout record names its session and
            # usage instead of looking like a run that never started (#718).
            for thread in readers[:2]:
                thread.join(timeout=1)
            raise subprocess.TimeoutExpired(
                args, timeout,
                output=(process_started + b"".join(retained)).decode(errors="replace"),
                stderr=stderr.decode(errors="replace"),
            ) from None
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
        # The run's last word on its plan, so the card settles where it ended.
        self.poll_plan(wait=True)
        completed = subprocess.CompletedProcess(args, proc.returncode,
                                                (process_started + b"".join(retained)).decode(errors="replace"),
                                                stderr.decode(errors="replace"))
        completed.work_seen = work_seen
        completed.source_gap = gap_seen
        return completed

    def finish(self, response):
        body_response, status = response if isinstance(response, tuple) else (response, 200)
        body = body_response.get_json() if hasattr(body_response, "get_json") else body_response
        body = body if isinstance(body, dict) else {}
        outcome = "timed_out" if status == 504 else ("failed" if status >= 400 else "completed")
        if not self.attempt_id:
            self.begin_attempt()
        if self.silence:
            logging.getLogger(__name__).info("silence clock run_id=%s %s", self.run_id,
                                             self.silence.finish(time.time()))
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

    def _arm_silence_clock(self, args, env):
        """Start the silence clock on the first attempt and hand chaos its steer file.

        Only conversation wakes have someone waiting to hear from the resident.
        An older chaos without `--steer-file` still gets the clock (for the
        measurement) but no flag it would reject."""
        conversation_id = getattr(self, "conversation_id", None)
        if not conversation_id:
            return args
        if self.silence is None:
            if self.voice_mode:
                self.silence = silence_nudge.SilenceClock(
                    self.run_id, conversation_id, time.time(),
                    first_after=silence_nudge.VOICE_FIRST_AFTER_SECS,
                    repeat=silence_nudge.VOICE_REPEAT_SECS,
                    ttl=silence_nudge.VOICE_NOTICE_TTL_SECS, voice=True)
            else:
                self.silence = silence_nudge.SilenceClock(
                    self.run_id, conversation_id, time.time(),
                    first_after=silence_nudge.FIRST_AFTER_SECS, repeat=silence_nudge.REPEAT_SECS)
        if not silence_nudge.supports_steer_file(args[0]):
            return args
        env["SOULSHOUSE_STEER_FILE"] = str(self.silence.path)
        return silence_nudge.with_steer_file(args, self.silence.path)

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
                        proposed = json.dumps(combined, ensure_ascii=False).encode()
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
                encoded = pending[0] if self.share else self._without_subagents(pending[0])
                if encoded is None:
                    with self.lock:
                        acknowledged = {id(entry) for entry in pending[1]}
                        self.queue = collections.deque(entry for entry in self.queue if id(entry) not in acknowledged)
                    pending = None
                    continue
                req = urllib.request.Request(self.url, data=encoded, method="POST",
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.token}"})
                with opener.open(req, timeout=5) as response:
                    ack = json.loads(response.read(ACK_MAX_BYTES))
                if self.silence and isinstance(ack, dict):
                    self.silence.observe_ack(ack, time.time())
                if ack.get("share_narration") is False:
                    self.share = False
                    with self.lock:
                        self.subagents = {}
                        self.queue = collections.deque(item for item in self.queue
                            if item[1] not in ("commentary.completed", "plan.updated", "agent.status_changed"))
                        retry_batches = collections.deque(batch for batch in retry_batches
                            if batch[1][0][1] not in ("commentary.completed", "plan.updated", "agent.status_changed"))
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

    @staticmethod
    def _without_subagents(encoded):
        packet = json.loads(encoded)
        packet["events"] = [event for event in packet["events"]
                            if event["type"] != "agent.status_changed"]
        if not packet["events"]:
            return None
        for event in packet["events"]:
            event["data"].pop("subagents", None)
        return json.dumps(packet, ensure_ascii=False).encode()
