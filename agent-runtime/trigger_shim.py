#!/usr/bin/env python3
"""
trigger_shim.py — the HTTP-to-chaos-exec bridge.

Runs inside each chaos-agent container. Listens on port 4000.
HelixKit POSTs a trigger payload here; we shell out to `chaos exec`.

This is intentionally dumb: no business logic, no decision-making beyond
"fresh session or resume". The only state it keeps is a sidecar cache mapping
HelixKit session ids to chaos process ids — losable at any moment with zero
correctness impact (loss means one fresh session, i.e. today's behaviour).

Endpoints:
    GET  /health          — liveness check (no auth)
    POST /trigger         — invoke chaos with a prompt (bearer-token auth)

Trigger payload (HelixKit ChaosTriggerClient shape):
    {
      "session_id": "<agent-uuid>-<chat-id>",     # HelixKit's stable session key
      "request": "HelixKit received a request...",# full prompt (always present)
      "request_delta": "...",                     # optional slim prompt, used only on resume
       "persistent_session": true,                 # optional; enables resume behaviour
       "roll_session": true,                       # optional; force a fresh mapped session
       "runtime_session_generation": 2,            # optional; roll when generation changes
       "conversation_id": "WYNWQe",                # optional, for logs only
       "requested_by": "user@example.com",         # optional, for logs only
       "provider": "anthropic",                    # optional; falls back to AGENT_PROVIDER env
       "model": "claude-sonnet-4-5",               # optional; falls back to AGENT_DEFAULT_MODEL env
       "reasoning_effort": "medium",                # optional; a Chaos reasoning effort
       "channel": "telegram",                      # optional channel-specific metadata
       "sender": {"name": "...", "email": "...", "telegram_username": "..."},
       "text": "incoming direct message",
       "thread_id": "stable-thread-id",
       "history_cursor": "latest-message-id"
     }

`prompt` is accepted as a backwards-compatible alias for `request`.

Persistent-session behaviour (when `persistent_session` is true):
    - First trigger for a session_id runs `chaos exec --json` with the full
      identity-wrapped prompt, captures chaos's process_id from the
      `process.started` event, and stores the mapping in a sidecar file under
      `$CHAOS_HOME/helixkit-sessions/`.
    - Subsequent triggers run `chaos exec --json ... resume <process_id> -`
      with `request_delta` (falling back to `request`) — no identity
      re-injection, no journal re-read.
    - The session rolls (fresh start) on: provider/model change,
      identity-file change, or any resume failure.
    - The response gains a versioned `telemetry` object describing the runtime,
      session decision, prompt sizes, and invocation-local usage. Existing
      top-level session and usage fields remain during migration.

Without `persistent_session`, each trigger still runs one fresh Chaos process
without a sidecar mapping, but JSON output is enabled so usage is observable.

Env vars (read at startup):
    AGENT_ID                  stable identifier for this agent
    AGENT_SLUG                optional human-readable identifier for logs
    TRIGGER_BEARER_TOKEN      required; the bearer token HelixKit must send on /trigger
    AGENT_DEFAULT_MODEL       default model name (e.g. "claude-haiku-4-5")
    AGENT_PROVIDER            chaos provider override (e.g. "anthropic")
    AGENT_REPO_PATH           agent repo path (default /home/agent/repo)
    AGENT_IDENTITY_PATH       identity path (default /home/agent/identity)
    AGENT_RUNTIME_DOCS_PATH   runtime documentation path
                              (default /usr/local/share/helixkit-agent)
    SHIM_PORT                 port to listen on (default 4000)
    CHAOS_BIN                 path to chaos binary (default /usr/local/bin/chaos)
    AGY_BIN                   path to Antigravity binary (default /usr/local/bin/agy)
    CHAOS_HOME                chaos state dir (default ~/.chaos); sidecar session
                               map lives under $CHAOS_HOME/helixkit-sessions/
    CHAOS_AGY_HOME            private Antigravity state (default /home/agent/state/antigravity)
    CHAOS_TIMEOUT_SECS        max seconds for a single chaos exec call (default 600)
"""

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import threading
import time
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse
try:
    from flask import Flask, request, jsonify, abort
except ModuleNotFoundError:  # Allows prompt-building tests without Flask installed.
    Flask = None
    request = None

    def jsonify(*_args, **_kwargs):
        raise RuntimeError("Flask is required to serve trigger_shim.py")

    def abort(*_args, **_kwargs):
        raise RuntimeError("Flask is required to serve trigger_shim.py")

# ----- config -----
AGENT_ID = os.environ.get("AGENT_ID", "unknown")
AGENT_LOG_LABEL = os.environ.get("AGENT_SLUG") or AGENT_ID
TRIGGER_BEARER_TOKEN = os.environ.get("TRIGGER_BEARER_TOKEN", "")
AGENT_DEFAULT_MODEL = os.environ.get("AGENT_DEFAULT_MODEL", "claude-haiku-4-5")
AGENT_PROVIDER = os.environ.get("AGENT_PROVIDER", "anthropic")
AGENT_REPO_PATH = Path(os.environ.get("AGENT_REPO_PATH", "/home/agent/repo"))
AGENT_IDENTITY_PATH = Path(os.environ.get("AGENT_IDENTITY_PATH", "/home/agent/identity"))
AGENT_RUNTIME_DOCS_PATH = Path(os.environ.get(
    "AGENT_RUNTIME_DOCS_PATH",
    "/usr/local/share/helixkit-agent",
))
SHIM_PORT = int(os.environ.get("SHIM_PORT", "4000"))
CHAOS_BIN = os.environ.get("CHAOS_BIN", "/usr/local/bin/chaos")
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "/usr/local/bin/claude")
AGY_BIN = os.environ.get("AGY_BIN", "/usr/local/bin/agy")
CODEXBAR_BIN = os.environ.get("CODEXBAR_BIN", "/usr/local/bin/codexbar")
SCRIPT_BIN = os.environ.get("SCRIPT_BIN", "/usr/bin/script")
ANTIGRAVITY_BROWSER_HELPER_DIR = Path(os.environ.get(
    "ANTIGRAVITY_BROWSER_HELPER_DIR",
    "/usr/local/libexec/helixkit-antigravity-login",
))
CHAOS_HOME = Path(os.environ.get("CHAOS_HOME", str(Path.home() / ".chaos")))
CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", "/home/agent/state/claude"))
CHAOS_AGY_HOME = Path(os.environ.get("CHAOS_AGY_HOME", "/home/agent/state/antigravity"))
CHAOS_TIMEOUT_SECS = int(os.environ.get("CHAOS_TIMEOUT_SECS", "600"))
CHAOS_ANTHROPIC_CACHE_TTL = os.environ.get("CHAOS_ANTHROPIC_CACHE_TTL")
SESSION_MAP_DIR = CHAOS_HOME / "helixkit-sessions"
OAUTH_CHAOS_HOME = CHAOS_HOME / "oauth-runtime"
OAUTH_ACCOUNT_PROVIDERS = tuple(
    provider.strip()
    for provider in os.environ.get(
        "CHAOS_OAUTH_ACCOUNT_PROVIDERS",
        "anthropic,gemini,openai,xai",
    ).split(",")
    if provider.strip()
)
PROVIDER_API_KEY_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "gemini": "GEMINI_API_KEY",
    "openai": "OPENAI_API_KEY",
    "xai": "XAI_API_KEY",
}
AUTH_CODE_TTL_SECS = 15 * 60
SUBSCRIPTION_USAGE_TTL_SECS = 60
SUBSCRIPTION_USAGE_TIMEOUT_SECS = 20
SHIM_TELEMETRY_SCHEMA_VERSION = 1
SIDECAR_SCHEMA_VERSION = 3
SUPPORTED_CHAOS_TELEMETRY_SCHEMA_VERSION = 1
SUPPORTED_REASONING_EFFORTS = (
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
    "ultra",
)
IDENTITY_FINGERPRINT_FILES = [
    "soul.md",
    "self-narrative.md",
    "bootstrap.md",
]
IDENTITY_FILE_LIMIT = 80_000
JOURNAL_MOST_RECENT_LIMIT = 12_000
JOURNAL_MOST_RECENT_TAIL = 10_000
JOURNAL_TOTAL_LIMIT = 16_000
USAGE_FIELDS = (
    "input_tokens",
    "uncached_input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "provider_request_count",
)

logging.basicConfig(
    level=logging.INFO,
    format=f"%(asctime)s [{AGENT_LOG_LABEL}] %(levelname)s %(message)s",
)
log = logging.getLogger(AGENT_LOG_LABEL)

if not TRIGGER_BEARER_TOKEN:
    log.error("TRIGGER_BEARER_TOKEN not set; shim will reject all /trigger calls. Refusing to start.")
    raise SystemExit(2)

app = Flask(__name__) if Flask else None

# Per-session locks prevent duplicate invocations from running concurrently
# against the same logical conversation/session while allowing the resident to
# handle independent conversations and channels at the same time.
_session_locks = {}
_session_locks_guard = threading.Lock()
_auth_lock = threading.Lock()
_auth_process = None
_auth_state = {"status": "none"}
_auth_code_ready = threading.Event()
_subscription_usage_cache = {}
_subscription_usage_locks = {}
_subscription_usage_guard = threading.Lock()


# ----- routes -----
def health():
    return jsonify({"status": "ok", "agent_id": AGENT_ID, "version": _chaos_version()})


def trigger():
    auth = request.headers.get("Authorization", "")
    if auth != f"Bearer {TRIGGER_BEARER_TOKEN}":
        log.warning("rejected /trigger: bad auth")
        abort(401)

    payload = request.get_json(silent=True) or {}
    session_id = payload.get("session_id")
    # `request` is the canonical field name (HelixKit ChaosTriggerClient). `prompt`
    # is accepted as a backwards-compatible alias for hand-rolled clients.
    prompt = payload.get("request") or payload.get("prompt")
    request_delta = payload.get("request_delta")
    persistent_session = bool(payload.get("persistent_session"))
    roll_session = bool(payload.get("roll_session"))
    runtime_session_generation = _optional_int(payload.get("runtime_session_generation")) or 0
    provider = payload.get("provider", AGENT_PROVIDER)
    model = payload.get("model", AGENT_DEFAULT_MODEL)
    reasoning_effort = payload.get("reasoning_effort")
    auth_mode = payload.get("auth_mode", "api_key")
    timeout_secs = int(payload.get("timeout_secs") or CHAOS_TIMEOUT_SECS)
    conversation_id = payload.get("conversation_id")
    requested_by = payload.get("requested_by")

    if not session_id or not prompt:
        return jsonify({"error": "session_id and `request` (or `prompt`) are required"}), 400
    if reasoning_effort is not None and reasoning_effort not in SUPPORTED_REASONING_EFFORTS:
        return jsonify({
            "error": f"reasoning_effort must be one of {', '.join(SUPPORTED_REASONING_EFFORTS)}"
        }), 400
    if auth_mode not in ("api_key", "oauth_account"):
        return jsonify({"error": "auth_mode must be api_key or oauth_account"}), 400

    if auth_mode == "oauth_account":
        usage = subscription_usage(provider, model)
        if usage.get("status") == "limited":
            return jsonify({
                "status": "error",
                "error_kind": "subscription_limit",
                "subscription_usage": usage,
            }), 429

    log.info(
        f"trigger session_id={session_id} conversation_id={conversation_id} "
        f"requested_by={requested_by} provider={provider} model={model} "
        f"reasoning_effort={reasoning_effort or 'model-default'} timeout_secs={timeout_secs} "
        f"prompt_len={len(prompt)} persistent={persistent_session} "
        f"delta_len={len(request_delta) if request_delta else 0}"
    )

    session_lock = _lock_for(session_id)
    if not session_lock.acquire(blocking=False):
        log.warning(f"session busy session_id={session_id}")
        return jsonify({
            "status": "already_running",
            "session_id": session_id,
        }), 409

    try:
        if persistent_session:
            return persistent_trigger(
                session_id, prompt, request_delta, model, timeout_secs,
                provider=provider, reasoning_effort=reasoning_effort, auth_mode=auth_mode,
                session_lock=session_lock, roll_session=roll_session,
                runtime_session_generation=runtime_session_generation,
            )
        return legacy_trigger(
            session_id, prompt, model, timeout_secs,
            provider=provider, reasoning_effort=reasoning_effort, auth_mode=auth_mode,
        )
    finally:
        session_lock.release()


def legacy_trigger(
    session_id, prompt, model, timeout_secs, provider=None,
    reasoning_effort=None, auth_mode="api_key",
):
    """Run a fresh, unmapped Chaos process while still capturing JSON telemetry."""
    provider = provider or AGENT_PROVIDER
    full_prompt, prompt_components = build_prompt_with_components(prompt)
    prompt_info = prompt_telemetry(
        full_prompt=full_prompt,
        delta_prompt=None,
        selected_prompt=full_prompt,
        mode="full",
        components=prompt_components,
    )

    try:
        result = run_chaos(
            model, timeout_secs, full_prompt, json_output=True,
            provider=provider, reasoning_effort=reasoning_effort,
            **({"auth_mode": auth_mode} if auth_mode != "api_key" else {}),
        )
    except subprocess.TimeoutExpired as error:
        log.error(f"chaos exec timed out after {timeout_secs}s")
        return timeout_response(
            session_id=session_id,
            timeout_secs=timeout_secs,
            runtime=runtime_telemetry(provider, model, timeout_secs),
            session=session_telemetry(
                session_id=session_id,
                mapping_found=False,
                resume_attempted=False,
                outcome="failed",
                roll_reason=None,
                changed_identity_files=[],
                prior_process_id=None,
                process_id=None,
                record=None,
                trigger_sequence=1,
                persistent_requested=False,
            ),
            prompt=prompt_info,
            timeout_error=error,
            invocation_text=full_prompt,
            resumed=False,
            fresh_fallback=False,
        )

    events = parse_events(result.stdout)
    usage = invocation_usage(None, events)
    outcome = "legacy_fresh" if result.returncode == 0 else "failed"
    return instrumented_response(
        session_id,
        result,
        events,
        full_prompt,
        usage=usage,
        runtime=runtime_telemetry(provider, model, timeout_secs, events),
        session=session_telemetry(
            session_id=session_id,
            mapping_found=False,
            resume_attempted=False,
            outcome=outcome,
            roll_reason=None,
            changed_identity_files=[],
            prior_process_id=None,
            process_id=events["process_id"],
            record=None,
            trigger_sequence=1,
            persistent_requested=False,
        ),
        prompt=prompt_info,
        resumed=False,
        fresh_fallback=False,
        roll=None,
    )


def persistent_trigger(
    session_id, prompt, request_delta, model, timeout_secs,
    provider=None, reasoning_effort=None, auth_mode="api_key", session_lock=None,
    roll_session=False, runtime_session_generation=0,
):
    """Resume the session mapped to session_id, or start (and record) a fresh one.

    A resume that fails in any detectable way is retried once as a full fresh
    turn. Chaos reveals a stale id only after the attempted run, so the retry
    repairs future context but cannot undo side effects from that rare attempt.
    """
    lock = session_lock or _lock_for(session_id)
    lock_acquired_here = session_lock is None
    if lock_acquired_here and not lock.acquire(blocking=False):
        log.warning(f"session busy session_id={session_id}")
        return jsonify({
            "status": "already_running",
            "session_id": session_id,
            "telemetry": build_telemetry(
                runtime=runtime_telemetry(provider or AGENT_PROVIDER, model, timeout_secs),
                session={
                    "logical_session_id": session_id,
                    "persistent_requested": True,
                    "mapping_found": None,
                    "resume_attempted": False,
                    "outcome": "already_running",
                    "roll_reason": None,
                    "changed_identity_files": [],
                    "prior_chaos_process_id": None,
                    "chaos_process_id": None,
                    "trigger_sequence": None,
                    "session_age_seconds": None,
                },
                prompt=None,
                usage=None,
            ),
        }), 409

    try:
        provider = provider or AGENT_PROVIDER
        prior_attempt = None
        record = load_session_record(session_id)
        mapping_found = record is not None
        prior_process_id = record.get("chaos_process_id") if record else None
        roll, changed_identity_files = (
            roll_decision(
                record, model, provider, auth_mode=auth_mode,
                roll_session=roll_session,
                runtime_session_generation=runtime_session_generation,
            )
            if record else ("safeguard-detected" if roll_session else None, [])
        )
        if record and roll:
            log.info(f"rolling session session_id={session_id} reason={roll}")
            retire_session_record(session_id, reason=roll)
            record = None

        if record:
            resume_prompt = request_delta or prompt
            prompt_info = prompt_telemetry(
                full_prompt=None,
                delta_prompt=request_delta,
                selected_prompt=resume_prompt,
                mode="delta",
                components=None,
            )
            try:
                result = run_chaos(
                    model, timeout_secs, resume_prompt,
                    json_output=True, resume_id=record["chaos_process_id"], provider=provider,
                    reasoning_effort=reasoning_effort,
                    **({"auth_mode": auth_mode} if auth_mode != "api_key" else {}),
                )
            except subprocess.TimeoutExpired as error:
                # The subprocess is killed on timeout, so the persisted session
                # may contain only part of this turn. Retire the ambiguous
                # mapping: the next trigger will use the full prompt instead of
                # replaying the same delta into a possibly half-written turn.
                log.error(f"chaos resume timed out after {timeout_secs}s session_id={session_id}")
                retire_session_record(session_id, reason="resume-timeout")
                return timeout_response(
                    session_id=session_id,
                    timeout_secs=timeout_secs,
                    runtime=runtime_telemetry(provider, model, timeout_secs),
                    session=session_telemetry(
                        session_id=session_id,
                        mapping_found=True,
                        resume_attempted=True,
                        outcome="resume_timeout",
                        roll_reason="resume-timeout",
                        changed_identity_files=[],
                        prior_process_id=prior_process_id,
                        process_id=prior_process_id,
                        record=record,
                    ),
                    prompt=prompt_info,
                    timeout_error=error,
                    usage_record=record,
                    invocation_text=resume_prompt,
                    resumed=False,
                    fresh_fallback=False,
                )

            events = parse_events(result.stdout)
            stale = events["process_id"] != record["chaos_process_id"]
            if result.returncode == 0 and not stale:
                usage = invocation_usage(record, events)
                next_sequence = next_trigger_sequence(record)
                update_session_record(session_id, record, events)
                return instrumented_response(
                    session_id, result, events, resume_prompt,
                    usage=usage,
                    runtime=runtime_telemetry(provider, model, timeout_secs, events),
                    session=session_telemetry(
                        session_id=session_id,
                        mapping_found=True,
                        resume_attempted=True,
                        outcome="resumed",
                        roll_reason=None,
                        changed_identity_files=[],
                        prior_process_id=prior_process_id,
                        process_id=events["process_id"],
                        record=record,
                        trigger_sequence=next_sequence,
                    ),
                    prompt=prompt_info,
                    resumed=True,
                    fresh_fallback=False,
                    roll=None,
                )

            log.warning(
                f"resume failed session_id={session_id} rc={result.returncode} "
                f"stale={stale} mapped={record['chaos_process_id']} got={events['process_id']}"
            )
            retire_session_record(session_id, reason="resume-failed")
            prior_attempt = {
                "usage": invocation_usage(record, events),
                "detailed": events["telemetry_status"] == "detailed",
            }
            if prior_attempt["detailed"] and result.returncode != 0:
                prior_attempt["usage"] = dict(prior_attempt["usage"] or {})
                prior_attempt["usage"]["complete"] = False
            roll = roll or "resume-failed"
            changed_identity_files = []

        # Fresh path: full identity-wrapped prompt, new session, new mapping.
        # Build this only after deciding not to resume. Reading journals on a
        # successful resume is unnecessary work and can make an append appear
        # to affect a turn whose actual prompt contains only the delta.
        full_prompt, prompt_components = build_prompt_with_components(prompt)
        prompt_info = prompt_telemetry(
            full_prompt=full_prompt,
            delta_prompt=request_delta,
            selected_prompt=full_prompt,
            mode="full",
            components=prompt_components,
        )
        try:
            result = run_chaos(
                model, timeout_secs, full_prompt, json_output=True,
                provider=provider, reasoning_effort=reasoning_effort,
                **({"auth_mode": auth_mode} if auth_mode != "api_key" else {}),
            )
        except subprocess.TimeoutExpired as error:
            log.error(f"chaos exec timed out after {timeout_secs}s session_id={session_id}")
            outcome = "fresh_fallback" if roll == "resume-failed" else ("rolled" if mapping_found else "failed")
            return timeout_response(
                session_id=session_id,
                timeout_secs=timeout_secs,
                runtime=runtime_telemetry(provider, model, timeout_secs),
                session=session_telemetry(
                    session_id=session_id,
                    mapping_found=mapping_found,
                    resume_attempted=(roll == "resume-failed"),
                    outcome=outcome,
                    roll_reason=roll,
                    changed_identity_files=changed_identity_files,
                    prior_process_id=prior_process_id,
                    process_id=None,
                    record=None,
                    trigger_sequence=1,
                ),
                prompt=prompt_info,
                timeout_error=error,
                invocation_text=full_prompt,
                resumed=False,
                fresh_fallback=(roll == "resume-failed"),
                roll=roll,
                prior_attempt=prior_attempt,
            )

        events = parse_events(result.stdout)
        usage = invocation_usage(None, events)
        if result.returncode == 0 and events["process_id"]:
            save_session_record(
                session_id, model, events, provider=provider, auth_mode=auth_mode,
                runtime_session_generation=runtime_session_generation,
            )
        if result.returncode != 0:
            outcome = "failed"
        elif roll == "resume-failed":
            outcome = "fresh_fallback"
        elif mapping_found:
            outcome = "rolled"
        else:
            outcome = "fresh"
        return instrumented_response(
            session_id, result, events, full_prompt,
            usage=usage,
            runtime=runtime_telemetry(provider, model, timeout_secs, events),
            session=session_telemetry(
                session_id=session_id,
                mapping_found=mapping_found,
                resume_attempted=(roll == "resume-failed"),
                outcome=outcome,
                roll_reason=roll,
                changed_identity_files=changed_identity_files,
                prior_process_id=prior_process_id,
                process_id=events["process_id"],
                record=None,
                trigger_sequence=1,
            ),
            prompt=prompt_info,
            resumed=False,
            fresh_fallback=(roll == "resume-failed"),
            roll=roll,
            prior_attempt=prior_attempt,
        )
    finally:
        if lock_acquired_here:
            lock.release()


# ----- chaos invocation -----
def run_chaos(
    model, timeout_secs, prompt_text, json_output,
    resume_id=None, provider=None, reasoning_effort=None, auth_mode="api_key",
):
    args = [CHAOS_BIN, "exec"]
    if json_output:
        # Machine-readable JSONL: process.started carries the process_id we
        # map for resume; turn.completed carries token usage.
        args.append("--json")
    cwd = AGENT_REPO_PATH if AGENT_REPO_PATH.exists() else Path.home()
    args += [
        "--provider", provider or AGENT_PROVIDER,
        "-C", str(cwd),
        "--skip-git-repo-check",
        "-m", model,
        # Docker is the sandbox boundary for hosted agents. Inside that
        # boundary the agent must be able to use Bash, write its mounted
        # identity/state folders, and call HelixKit's API back.
        "--headless",
        "-c", "shell_environment_policy.inherit=\"all\"",
    ]
    selected_provider = provider or AGENT_PROVIDER
    if auth_mode == "oauth_account" and selected_provider == "anthropic":
        # Headless clamp is startup config, so this applies equally to fresh and
        # resumed exec sessions. Bare mode remains false for credential lookup.
        args += ["-c", "clamp=true"]
    elif auth_mode == "oauth_account" and selected_provider == "gemini":
        # Antigravity uses the same Chaos-owned MCP bridge as Claude Code, but
        # selects Google's official agy subprocess as the clamp transport.
        args += ["-c", "clamp=true", "-c", "clamp_backend=antigravity"]
    if reasoning_effort:
        args += ["-c", f'model_reasoning_effort="{reasoning_effort}"']
    if resume_id:
        # `resume` is an exec subcommand; root exec flags stay before it.
        args += ["resume", resume_id]
    # Read the full prompt from stdin so identity injection is not
    # constrained by shell argv limits and is not exposed in ps args.
    args.append("-")

    env = os.environ.copy()
    if auth_mode == "oauth_account":
        if selected_provider == "anthropic":
            env = _anthropic_subscription_env()
        elif selected_provider == "gemini":
            env = _antigravity_subscription_env()
        else:
            env = _oauth_account_env()
        api_key_env = PROVIDER_API_KEY_ENV.get(selected_provider)
        if api_key_env:
            env.pop(api_key_env, None)
    return subprocess.run(
        args,
        input=prompt_text,
        capture_output=True,
        text=True,
        timeout=timeout_secs,
        env=env,
    )


def parse_events(stdout):
    """Parse `chaos exec --json` JSONL output.

    Version-1 Chaos telemetry is invocation-local and safe to persist directly.
    Older events are retained as explicitly legacy cumulative counters so they
    cannot accidentally populate the new detailed usage fields.
    """
    parsed = {
        "process_id": None,
        "telemetry_schema_version": None,
        "telemetry_status": "missing",
        "usage": None,
        "session_usage": None,
        "unsupported_telemetry_schema_version": None,
        "legacy_cumulative_usage": None,
        # Compatibility aliases for the old cumulative subtraction path.
        "input_tokens": 0,
        "cached_input_tokens": 0,
        "output_tokens": 0,
        "agent_messages": [],
        "errors": [],
    }
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("type")
        if kind == "process.started":
            parsed["process_id"] = event.get("process_id")
        elif kind in ("turn.completed", "invocation.completed"):
            _parse_completion_event(parsed, event)
        elif kind == "item.completed":
            item = event.get("item") or {}
            if item.get("type") == "agent_message" and item.get("text"):
                parsed["agent_messages"].append(item["text"])
        elif kind in ("error", "turn.failed"):
            parsed["errors"].append(json.dumps(event))
    return parsed


def _parse_completion_event(parsed, event):
    usage = event.get("usage") or {}
    schema_version = _optional_int(event.get("telemetry_schema_version"))
    parsed.update({
        "telemetry_schema_version": schema_version,
        "telemetry_status": "missing",
        "usage": None,
        "session_usage": None,
        "unsupported_telemetry_schema_version": None,
        "legacy_cumulative_usage": None,
        "input_tokens": 0,
        "cached_input_tokens": 0,
        "output_tokens": 0,
    })

    if schema_version is None:
        legacy = {
            "input_tokens": _int_or_zero(usage.get("input_tokens")),
            "cached_input_tokens": _int_or_zero(usage.get("cached_input_tokens")),
            "output_tokens": _int_or_zero(usage.get("output_tokens")),
        }
        if _has_additive_legacy_usage(usage):
            cache_read = (
                usage.get("cache_read_input_tokens")
                if "cache_read_input_tokens" in usage
                else usage.get("cached_input_tokens")
            )
            legacy.update({
                "uncached_input_tokens": _optional_int(usage.get("uncached_input_tokens")),
                "cache_creation_input_tokens": _optional_int(usage.get("cache_creation_input_tokens")),
                "cache_read_input_tokens": _optional_int(cache_read),
                "reasoning_output_tokens": _optional_int(usage.get("reasoning_output_tokens")),
                "provider_request_count": _optional_int(usage.get("provider_request_count")),
            })
        parsed["telemetry_status"] = "legacy"
        parsed["legacy_cumulative_usage"] = legacy
        parsed.update(legacy)
        return

    if schema_version != SUPPORTED_CHAOS_TELEMETRY_SCHEMA_VERSION:
        parsed["telemetry_status"] = "unsupported"
        parsed["unsupported_telemetry_schema_version"] = schema_version
        return

    if usage.get("scope") != "invocation":
        parsed["telemetry_status"] = "invalid_scope"
        return

    parsed["telemetry_status"] = "detailed"
    parsed["usage"] = normalize_usage(usage)
    session_usage = event.get("session_usage")
    if isinstance(session_usage, dict) and session_usage.get("scope") == "process_cumulative":
        parsed["session_usage"] = normalize_usage(session_usage)


def normalize_usage(usage):
    normalized = {"scope": usage.get("scope")}
    for field in USAGE_FIELDS:
        value = usage.get(field)
        if field == "cache_read_input_tokens" and field not in usage:
            value = usage.get("cached_input_tokens")
        normalized[field] = _optional_int(value)
    if "complete" in usage:
        normalized["complete"] = usage["complete"] if isinstance(usage["complete"], bool) else None
    return normalized


def invocation_usage(record, events):
    """Return new invocation-local usage, or a coarse old-runtime fallback."""
    if events["telemetry_status"] == "detailed":
        return events["usage"]
    if events["telemetry_status"] == "legacy":
        return usage_since(record, events)
    return None


def usage_since(record, events):
    """Compatibility only: subtract old Chaos process-cumulative counters."""
    record = record or {}
    usage = {}
    cumulative_usage = events.get("legacy_cumulative_usage") or {
        key: events.get(key)
        for key in ("input_tokens", "cached_input_tokens", "output_tokens")
    }
    for key, current_value in cumulative_usage.items():
        if current_value is None:
            usage[key] = None
            continue
        previous = int(record.get(f"cumulative_{key}") or 0)
        current = int(current_value)
        # A future Chaos compaction or accounting change may reset a cumulative
        # counter. Treat the new value as this trigger's usage rather than
        # incorrectly reporting zero forever after the reset.
        usage[key] = current - previous if current >= previous else current
    return usage


def instrumented_response(
    session_id,
    result,
    events,
    invocation_text,
    usage,
    runtime,
    session,
    prompt,
    resumed,
    fresh_fallback,
    roll,
    prior_attempt=None,
):
    # Prefer the agent's own message texts as diagnostics; fall back to raw
    # JSONL tail so failures stay debuggable.
    if events["agent_messages"]:
        stdout_text = "\n\n".join(events["agent_messages"])
    else:
        stdout_text = result.stdout
    if events["errors"]:
        stdout_text += "\n\n[events] " + "\n".join(events["errors"])

    telemetry_usage = response_invocation_usage(events, result.returncode)
    compatibility_usage = compatibility_usage_fields(telemetry_usage or usage)
    chaos_telemetry_status = events["telemetry_status"]
    if prior_attempt:
        compatibility_usage = aggregate_attempt_usage(
            compatibility_usage_fields(prior_attempt.get("usage")),
            compatibility_usage,
        )
        compatibility_usage = compatibility_usage_fields(compatibility_usage)
        if prior_attempt.get("detailed") and telemetry_usage is not None:
            telemetry_usage = aggregate_attempt_usage(prior_attempt.get("usage"), telemetry_usage)
        else:
            telemetry_usage = None
            chaos_telemetry_status = "mixed"
    if result.returncode != 0:
        compatibility_usage = dict(compatibility_usage)
        compatibility_usage["complete"] = False
    response = {
        "status": "ok" if result.returncode == 0 else "error",
        "session_id": session_id,
        "returncode": result.returncode,
        "stdout": _tail(stdout_text, 4000),
        "stderr": _tail(result.stderr, 4000),
        "full_invocation_text": invocation_text,
        "chaos_session_id": events["process_id"],
        "session_resumed": resumed,
        "fresh_fallback": fresh_fallback,
        "usage": compatibility_usage,
        "telemetry": build_telemetry(
            runtime=runtime,
            session=session,
            prompt=prompt,
            usage=telemetry_usage,
            session_usage=events["session_usage"],
            chaos_telemetry_status=chaos_telemetry_status,
            unsupported_chaos_schema=events["unsupported_telemetry_schema_version"],
        ),
    }
    if roll:
        response["session_roll_reason"] = roll
    error_kind = classify_provider_error(response, runtime.get("provider"))
    if error_kind:
        response["error_kind"] = error_kind
        if error_kind == "subscription_limit":
            cached_usage = cached_subscription_usage(
                runtime.get("provider"),
                runtime.get("model"),
            )
            if cached_usage:
                response["subscription_usage"] = cached_usage
    log.info(
        f"trigger done session_id={session_id} rc={result.returncode} resumed={resumed} "
        f"chaos_session={events['process_id']} "
        f"telemetry={events['telemetry_status']} "
        f"usage=i{compatibility_usage.get('input_tokens')}/"
        f"c{compatibility_usage.get('cached_input_tokens')}/"
        f"o{compatibility_usage.get('output_tokens')}"
    )
    return jsonify(response), (200 if result.returncode == 0 else 500)


def response_invocation_usage(events, returncode):
    """Return detailed usage, marking failed shim invocations incomplete."""
    if events["telemetry_status"] != "detailed":
        return None
    usage = dict(events["usage"])
    if returncode != 0:
        usage["complete"] = False
    return usage


def compatibility_usage_fields(usage):
    if not usage:
        return {}
    if "cache_read_input_tokens" in usage:
        return {
            **usage,
            "cached_input_tokens": usage.get("cache_read_input_tokens"),
        }
    return usage


def aggregate_attempt_usage(first, second):
    """Aggregate all Chaos invocations caused by one HelixKit trigger."""
    if not first:
        return second or {}
    if not second:
        return first or {}

    aggregate = {"scope": "trigger"}
    for field in USAGE_FIELDS:
        left = first.get(field)
        if field == "cache_read_input_tokens" and left is None:
            left = first.get("cached_input_tokens")
        right = second.get(field)
        if field == "cache_read_input_tokens" and right is None:
            right = second.get("cached_input_tokens")
        aggregate[field] = left + right if left is not None and right is not None else None

    complete_values = [usage.get("complete") for usage in (first, second)]
    aggregate["complete"] = all(value is not False for value in complete_values)
    return aggregate


def build_telemetry(
    runtime,
    session,
    prompt,
    usage,
    session_usage=None,
    chaos_telemetry_status=None,
    unsupported_chaos_schema=None,
):
    telemetry = {
        "schema_version": SHIM_TELEMETRY_SCHEMA_VERSION,
        "runtime": runtime,
        "session": session,
        "prompt": prompt,
        "usage": usage,
    }
    if session_usage is not None:
        telemetry["session_usage"] = session_usage
    if chaos_telemetry_status:
        telemetry["chaos_telemetry_status"] = chaos_telemetry_status
    if unsupported_chaos_schema is not None:
        telemetry["unsupported_chaos_telemetry_schema_version"] = unsupported_chaos_schema
    return telemetry


def runtime_telemetry(provider, model, timeout_secs, events=None):
    return {
        "chaos_version": _chaos_version(),
        "provider": provider,
        "model": model,
        "cache_ttl": effective_cache_ttl(provider),
        "timeout_seconds": timeout_secs,
        "chaos_telemetry_schema_version": (
            events.get("telemetry_schema_version") if events else None
        ),
    }


def effective_cache_ttl(provider):
    if provider != "anthropic":
        return "unknown"
    value = (CHAOS_ANTHROPIC_CACHE_TTL or "").strip().lower()
    return value if value in ("off", "5m", "1h") else "unknown"


def session_telemetry(
    session_id,
    mapping_found,
    resume_attempted,
    outcome,
    roll_reason,
    changed_identity_files,
    prior_process_id,
    process_id,
    record,
    trigger_sequence=None,
    persistent_requested=True,
):
    return {
        "logical_session_id": session_id,
        "persistent_requested": persistent_requested,
        "mapping_found": mapping_found,
        "resume_attempted": resume_attempted,
        "outcome": outcome,
        "roll_reason": roll_reason,
        "changed_identity_files": changed_identity_files,
        "prior_chaos_process_id": prior_process_id,
        "chaos_process_id": process_id,
        "sidecar_created_at": record.get("created_at") if record else None,
        "sidecar_last_finished_at": record.get("last_finished_at") if record else None,
        "session_age_seconds": _session_age_seconds(record),
        "trigger_sequence": trigger_sequence,
    }


def timeout_response(
    session_id,
    timeout_secs,
    runtime,
    session,
    prompt,
    timeout_error=None,
    usage_record=None,
    invocation_text=None,
    resumed=False,
    fresh_fallback=False,
    roll=None,
    prior_attempt=None,
):
    stdout = _timeout_stream(timeout_error, "stdout")
    stderr = _timeout_stream(timeout_error, "stderr")
    events = parse_events(stdout)
    usage = invocation_usage(usage_record, events)
    telemetry_usage = response_invocation_usage(events, returncode=1)
    compatibility_usage = compatibility_usage_fields(telemetry_usage or usage)
    chaos_telemetry_status = "incomplete"
    if prior_attempt:
        compatibility_usage = aggregate_attempt_usage(
            compatibility_usage_fields(prior_attempt.get("usage")),
            compatibility_usage,
        )
        compatibility_usage = compatibility_usage_fields(compatibility_usage)
        if prior_attempt.get("detailed") and telemetry_usage is not None:
            telemetry_usage = aggregate_attempt_usage(prior_attempt.get("usage"), telemetry_usage)
        else:
            telemetry_usage = None
            chaos_telemetry_status = "mixed_incomplete"
    compatibility_usage["complete"] = False

    runtime = dict(runtime)
    runtime["chaos_telemetry_schema_version"] = events["telemetry_schema_version"]
    session = dict(session)
    if not session.get("chaos_process_id") and events["process_id"]:
        session["chaos_process_id"] = events["process_id"]

    response = {
        "status": "timeout",
        "session_id": session_id,
        "timeout_secs": timeout_secs,
        "returncode": None,
        "stdout": _tail(stdout, 4000),
        "stderr": _tail(stderr, 4000),
        "full_invocation_text": invocation_text,
        "chaos_session_id": session.get("chaos_process_id"),
        "session_resumed": resumed,
        "fresh_fallback": fresh_fallback,
        "usage": compatibility_usage,
        "telemetry": build_telemetry(
            runtime=runtime,
            session=session,
            prompt=prompt,
            usage=telemetry_usage,
            session_usage=events["session_usage"],
            chaos_telemetry_status=chaos_telemetry_status,
            unsupported_chaos_schema=events["unsupported_telemetry_schema_version"],
        ),
    }
    if roll:
        response["session_roll_reason"] = roll
    return jsonify(response), 504


# ----- session sidecar records -----
def session_record_path(session_id):
    # Session ids are caller-supplied; never place them raw into a path.
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session_id)[:80]
    digest = hashlib.sha256(session_id.encode()).hexdigest()[:12]
    return SESSION_MAP_DIR / f"{safe}-{digest}.json"


def load_session_record(session_id):
    path = session_record_path(session_id)
    try:
        record = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except Exception as e:
        log.warning(f"unreadable session record {path}: {e}")
        return None
    if not record.get("chaos_process_id"):
        return None
    return record


def save_session_record(
    session_id, model, events, provider=None, auth_mode="api_key",
    runtime_session_generation=0,
):
    now = _utcnow_iso()
    record = {
        "schema_version": SIDECAR_SCHEMA_VERSION,
        "helixkit_session_id": session_id,
        "chaos_process_id": events["process_id"],
        "provider": provider or AGENT_PROVIDER,
        "auth_mode": auth_mode,
        "model": model,
        "runtime_session_generation": runtime_session_generation,
        "created_at": now,
        "last_finished_at": now,
        "trigger_sequence": 1,
        "identity_fingerprint": identity_fingerprint(),
        "runtime_context_fingerprint": runtime_context_fingerprint(),
    }
    _store_legacy_cumulative_usage(record, events)
    _atomic_write(session_record_path(session_id), record)


def update_session_record(session_id, record, events):
    record["schema_version"] = SIDECAR_SCHEMA_VERSION
    record["last_finished_at"] = _utcnow_iso()
    record["trigger_sequence"] = next_trigger_sequence(record)
    record["identity_fingerprint"] = identity_fingerprint()
    _store_legacy_cumulative_usage(record, events)
    _atomic_write(session_record_path(session_id), record)


def _store_legacy_cumulative_usage(record, events):
    legacy = events.get("legacy_cumulative_usage")
    if not legacy:
        return
    for key, value in legacy.items():
        if value is not None:
            record[f"cumulative_{key}"] = value


def retire_session_record(session_id, reason):
    path = session_record_path(session_id)
    try:
        path.rename(path.with_suffix(f".retired-{reason}.json"))
    except FileNotFoundError:
        pass
    except Exception as e:
        log.warning(f"could not retire session record {path}: {e}")
        try:
            path.unlink()
        except Exception:
            pass


def roll_decision(
    record, model, provider=None, auth_mode="api_key",
    roll_session=False, runtime_session_generation=0,
):
    """Return (reason, changed identity files); reason None means resume."""
    if roll_session:
        return "safeguard-detected", []
    schema_version = _optional_int(record.get("schema_version", 1))
    if schema_version is None or schema_version > SIDECAR_SCHEMA_VERSION:
        return "sidecar-schema-unsupported", []
    if record.get("provider", AGENT_PROVIDER) != (provider or AGENT_PROVIDER):
        return "provider-changed", []
    if record.get("model") != model:
        return "model-changed", []
    if record.get("auth_mode", "api_key") != auth_mode:
        return "auth-mode-changed", []
    if (_optional_int(record.get("runtime_session_generation")) or 0) != runtime_session_generation:
        return "requested-generation-changed", []
    changed_files = changed_identity_files(record.get("identity_fingerprint") or {})
    if changed_files:
        return "identity-changed", changed_files
    if record.get("runtime_context_fingerprint") != runtime_context_fingerprint():
        return "runtime-context-changed", []
    return None, []


def roll_reason(record, model, provider=None, auth_mode="api_key"):
    """Compatibility wrapper for callers that only need the reason."""
    reason, _changed_files = roll_decision(record, model, provider, auth_mode=auth_mode)
    return reason


def identity_fingerprint():
    """Content fingerprints for identity files that require a session roll."""
    fingerprint = {}
    for filename in IDENTITY_FINGERPRINT_FILES:
        path = AGENT_IDENTITY_PATH / filename
        try:
            content = path.read_bytes()
            fingerprint[filename] = {
                "sha256": hashlib.sha256(content).hexdigest(),
                "bytes": len(content),
            }
        except OSError:
            fingerprint[filename] = None
    return fingerprint


def changed_identity_files(previous_fingerprint):
    current = identity_fingerprint()
    changed = []
    for filename in IDENTITY_FINGERPRINT_FILES:
        previous = previous_fingerprint.get(filename)
        if isinstance(previous, int):
            # Schema-v1 sidecars stored mtimes. They can safely resume while the
            # mtime is unchanged; the next successful write upgrades to hashes.
            try:
                unchanged = AGENT_IDENTITY_PATH.joinpath(filename).stat().st_mtime_ns == previous
            except OSError:
                unchanged = previous is None
        else:
            unchanged = previous == current.get(filename)
        if not unchanged:
            changed.append(filename)
    return changed


def runtime_context_fingerprint():
    """Fingerprint the exact runtime section injected when a session is born."""
    content = runtime_context().encode("utf-8")
    return {
        "sha256": hashlib.sha256(content).hexdigest(),
        "bytes": len(content),
    }


def _atomic_write(path, record):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, indent=2))
        tmp.replace(path)
    except Exception as e:
        # Sidecar loss is safe (next trigger goes fresh); never fail the run.
        log.warning(f"could not write session record {path}: {e}")


def _lock_for(session_id):
    with _session_locks_guard:
        if session_id not in _session_locks:
            _session_locks[session_id] = threading.Lock()
        return _session_locks[session_id]


def _utcnow_iso():
    return datetime.now(timezone.utc).isoformat()


def _session_age_seconds(record):
    if not record or not record.get("created_at"):
        return 0 if record is None else None
    try:
        created_at = datetime.fromisoformat(record["created_at"])
        if created_at.tzinfo is None:
            created_at = created_at.replace(tzinfo=timezone.utc)
        return max(0, int((datetime.now(timezone.utc) - created_at).total_seconds()))
    except (TypeError, ValueError):
        return None


def next_trigger_sequence(record):
    """Increment old, missing, or malformed sidecar sequence values safely."""
    current = _optional_int((record or {}).get("trigger_sequence"))
    return max(0, current or 0) + 1


def _has_additive_legacy_usage(usage):
    return any(
        field in usage
        for field in (
            "uncached_input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
            "reasoning_output_tokens",
            "provider_request_count",
        )
    )


def _timeout_stream(error, name):
    value = getattr(error, name, None) if error else None
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value or ""


def _optional_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _int_or_zero(value):
    parsed = _optional_int(value)
    return parsed if parsed is not None else 0


def _byte_length(text):
    if text is None:
        return None
    return len(text.encode("utf-8"))


# ----- helpers -----
def _tail(s: str, n: int) -> str:
    """Trim long stdout/stderr so HelixKit doesn't choke on huge payloads."""
    if not s:
        return ""
    if len(s) <= n:
        return s
    return f"...[truncated {len(s) - n} chars]...\n{s[-n:]}"


def build_prompt(request_text: str) -> str:
    """Attach identity, the live request, and memory to every Chaos turn.

    Keep stable identity first, but place the current HelixKit trigger before
    diarized memory. The live request/transcript is ground truth for the current
    conversation; journals are continuity context and must not look like adjacent
    transcript.
    """
    prompt, _components = build_prompt_with_components(request_text)
    return prompt


def build_prompt_with_components(request_text):
    """Build a fresh prompt and return byte sizes without retaining its contents twice."""
    identity = identity_context()
    journals = memory_context()
    parts = [part for part in (identity, request_text, journals) if part]
    prompt = "\n\n".join(parts)
    return prompt, {
        "identity": _byte_length(identity),
        "request": _byte_length(request_text),
        "journal": _byte_length(journals),
    }


def prompt_telemetry(full_prompt, delta_prompt, selected_prompt, mode, components):
    return {
        "mode": mode,
        "full_prompt_bytes": _byte_length(full_prompt),
        "delta_prompt_bytes": _byte_length(delta_prompt),
        "selected_prompt_bytes": _byte_length(selected_prompt),
        "components": components or {},
    }


def identity_context() -> str:
    """Return identity and current hosting context, with soul first."""
    sections = []

    # Keep soul.md first. This is the agent's own chosen/exported identity text,
    # and should be the first thing the model sees before runtime scaffolding.
    soul = read_identity_file("soul.md")
    if soul:
        sections.append(soul)

    runtime = runtime_context()
    if runtime:
        sections.append(runtime)

    for filename, label in [
        ("self-narrative.md", "Self-narrative"),
        ("bootstrap.md", "Bootstrap notes"),
    ]:
        content = read_identity_file(filename)
        if content:
            sections.append(f"## {label}: identity/{filename}\n\n{content}")

    return "\n\n".join(sections)


def runtime_context() -> str:
    """Return the exact runtime-owned section injected into fresh sessions."""
    path = AGENT_RUNTIME_DOCS_PATH / "runtime-instructions.md"
    content = read_runtime_file(path)
    if not content:
        return ""

    notes = [
        (
            "This is hosting context supplied by the current runtime image, not "
            "part of your identity."
        ),
    ]
    legacy_paths = [
        AGENT_IDENTITY_PATH / "runtime-instructions.md",
        AGENT_IDENTITY_PATH / "runtime-instructions.md.new",
        AGENT_IDENTITY_PATH / "helixkit-api.md",
    ]
    if any(path.exists() for path in legacy_paths):
        notes.append(
            "If `identity/runtime-instructions.md`, "
            "`identity/runtime-instructions.md.new`, or "
            "`identity/helixkit-api.md` exists, it may be a historical export "
            "or contain your own annotations. These files are preserved, but "
            "the runtime-owned manual named below is authoritative."
        )

    return "\n\n".join([
        f"## Hosted runtime instructions: {path}",
        *notes,
        content,
    ])


def memory_context() -> str:
    """Return clearly labeled continuity context that is not live transcript."""
    journals = recent_journal_context()
    if not journals:
        return ""

    return "\n\n".join([
        "## Memory context — not current chat transcript",
        (
            "The following recent journals are diarized memory and continuity context. "
            "They are not current HelixKit chat messages, not trigger payload, and not "
            "the live transcript. If this turn includes a LIVE HELIXKIT TRANSCRIPT "
            "section, treat that section as the ground truth for the current conversation."
        ),
        journals,
    ])


def read_identity_file(filename: str) -> str:
    path = AGENT_IDENTITY_PATH / filename
    try:
        content = path.read_text()
    except FileNotFoundError:
        return ""
    except Exception as e:
        return f"_Could not read {path}: {e}_"

    if len(content) <= IDENTITY_FILE_LIMIT:
        return content
    return content[:IDENTITY_FILE_LIMIT] + f"\n\n_[truncated {len(content) - IDENTITY_FILE_LIMIT} chars]_"


def read_runtime_file(path: Path) -> str:
    try:
        content = path.read_text()
    except FileNotFoundError:
        return f"_Runtime documentation is missing at {path}._"
    except Exception as e:
        return f"_Could not read runtime documentation at {path}: {e}_"

    if len(content) <= IDENTITY_FILE_LIMIT:
        return content
    return content[:IDENTITY_FILE_LIMIT] + f"\n\n_[truncated {len(content) - IDENTITY_FILE_LIMIT} chars]_"


def recent_journal_context() -> str:
    """Read back recent diarized memory from the identity volume.

    This is memory, not instruction: the most recent daily journal is included
    verbatim (modulo tail truncation), and the previous two days show headings
    only as a cheap index for deeper filesystem reads.
    """
    journal_dir = AGENT_IDENTITY_PATH / "memory" / "daily-journals"
    try:
        files = sorted(journal_dir.glob("????-??-??.md"), reverse=True)
    except Exception as e:
        return f"## Your recent journal entries\n\n_Could not list {journal_dir}: {e}_"

    if not files:
        return ""

    sections = [
        "## Your recent journal entries",
        (
            "Diarized memory you wrote on earlier turns. The most recent day is "
            "shown in full; earlier days show entry titles only — read the full "
            "file under `memory/daily-journals/` if a title is relevant."
        ),
    ]

    remaining = JOURNAL_TOTAL_LIMIT
    latest = render_latest_journal(files[0])
    if latest:
        latest = cap_text(latest, remaining)
        sections.append(latest)
        remaining -= len(latest)

    for path in files[1:3]:
        if remaining <= 0:
            break
        headings = render_journal_headings(path)
        if headings:
            headings = cap_text(headings, remaining)
            sections.append(headings)
            remaining -= len(headings)

    return "\n\n".join(sections)


def render_latest_journal(path: Path) -> str:
    try:
        content = path.read_text()
    except Exception as e:
        return f"### {path.name}\n\n_Could not read {path}: {e}_"

    if len(content) > JOURNAL_MOST_RECENT_LIMIT:
        first_line = content.splitlines()[0] if content.splitlines() else f"# {path.name}"
        omitted = len(content) - JOURNAL_MOST_RECENT_TAIL
        content = f"{first_line}\n\n_[older content truncated: {omitted} chars]_\n\n{content[-JOURNAL_MOST_RECENT_TAIL:]}"

    return f"### {path.name} — full recent day\n\n{content}"


def render_journal_headings(path: Path) -> str:
    try:
        headings = [line.rstrip() for line in path.read_text().splitlines() if line.startswith("## ")]
    except Exception as e:
        return f"### {path.name} — headings only\n\n_Could not read {path}: {e}_"

    if not headings:
        return f"### {path.name} — headings only\n\n_No entry headings found._"

    return f"### {path.name} — headings only\n\n" + "\n".join(headings)


def cap_text(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    if limit <= 200:
        return text[:limit]
    return text[: limit - 80] + f"\n\n_[journal section truncated to fit {JOURNAL_TOTAL_LIMIT} chars]_"


# ----- provider subscription authentication -----
def _require_shim_auth(path):
    auth = request.headers.get("Authorization", "")
    if auth != f"Bearer {TRIGGER_BEARER_TOKEN}":
        log.warning(f"rejected {path}: bad auth")
        abort(401)


def _requested_auth_provider():
    payload = request.get_json(silent=True) or {}
    return payload.get("provider") or request.args.get("provider") or AGENT_PROVIDER


def auth_usage():
    _require_shim_auth("/auth/usage")
    provider = request.args.get("provider") or AGENT_PROVIDER
    model = request.args.get("model") or AGENT_DEFAULT_MODEL
    if provider not in OAUTH_ACCOUNT_PROVIDERS:
        return jsonify({"error": f"{provider} does not support subscription usage"}), 422
    return jsonify(subscription_usage(provider, model, refresh=request.args.get("refresh") == "1"))


def subscription_usage(provider, model, refresh=False):
    key = (provider, model)
    now = time.monotonic()
    with _subscription_usage_guard:
        cached = _subscription_usage_cache.get(key)
        if not refresh and cached and now - cached["cached_at"] < SUBSCRIPTION_USAGE_TTL_SECS:
            return _valid_cached_usage(cached["snapshot"])
        lock = _subscription_usage_locks.setdefault(key, threading.Lock())

    with lock:
        now = time.monotonic()
        with _subscription_usage_guard:
            cached = _subscription_usage_cache.get(key)
            if not refresh and cached and now - cached["cached_at"] < SUBSCRIPTION_USAGE_TTL_SECS:
                return _valid_cached_usage(cached["snapshot"])
        try:
            snapshot = USAGE_PROBES[provider](provider, model)
        except Exception as error:
            log.warning(f"subscription usage unavailable provider={provider}: {type(error).__name__}")
            with _subscription_usage_guard:
                cached = _subscription_usage_cache.get(key)
            if cached:
                usable = _last_good_after_failed_refresh(cached["snapshot"])
                if usable:
                    return usable
            return unknown_subscription_usage(provider)

        snapshot = normalize_subscription_usage(snapshot, provider, model)
        with _subscription_usage_guard:
            _subscription_usage_cache[key] = {
                "cached_at": time.monotonic(),
                "snapshot": snapshot,
            }
        return snapshot


def cached_subscription_usage(provider, model):
    if not provider or not model:
        return None
    with _subscription_usage_guard:
        cached = _subscription_usage_cache.get((provider, model))
    return _valid_cached_usage(cached["snapshot"]) if cached else None


def _valid_cached_usage(snapshot):
    if snapshot.get("status") != "limited":
        return snapshot
    resets = [
        _parse_timestamp(window.get("resets_at"))
        for window in snapshot.get("windows", [])
        if window.get("blocking")
    ]
    known_resets = [value for value in resets if value is not None]
    if known_resets and max(known_resets) <= datetime.now(timezone.utc):
        return unknown_subscription_usage(snapshot.get("provider"))
    return snapshot


def _last_good_after_failed_refresh(snapshot):
    snapshot = _valid_cached_usage(snapshot)
    if snapshot.get("status") == "unknown":
        return None
    resets = [
        _parse_timestamp(window.get("resets_at"))
        for window in snapshot.get("windows", [])
    ]
    now = datetime.now(timezone.utc)
    return snapshot if any(value is not None and value > now for value in resets) else None


def unknown_subscription_usage(provider):
    return {
        "provider": provider,
        "plan": None,
        "status": "unknown",
        "windows": [],
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "source": None,
    }


def probe_chaos_account_usage(provider, _model):
    result = subprocess.run(
        [CHAOS_BIN, "--provider", provider, "accounts", "usage", "--json"],
        capture_output=True,
        text=True,
        timeout=SUBSCRIPTION_USAGE_TIMEOUT_SECS,
        env=_oauth_account_env(),
    )
    if result.returncode != 0:
        raise RuntimeError("Chaos account usage probe failed")
    return json.loads(_bounded_output(result.stdout))


def probe_claude_usage(_provider, _model):
    status = _anthropic_account_status()
    if status.get("status") != "connected":
        raise RuntimeError("Claude subscription is not connected")
    return _codexbar_usage("claude", _anthropic_subscription_env())


def probe_antigravity_usage(_provider, _model):
    status = _antigravity_account_status()
    if status.get("status") != "connected":
        raise RuntimeError("Antigravity subscription is not connected")
    return _codexbar_usage("antigravity", _antigravity_cli_env())


def _codexbar_usage(provider, env):
    result = subprocess.run(
        [CODEXBAR_BIN, "usage", "--provider", provider, "--source", "cli", "--format", "json"],
        capture_output=True,
        text=True,
        timeout=SUBSCRIPTION_USAGE_TIMEOUT_SECS,
        env=env,
    )
    if result.returncode != 0:
        raise RuntimeError("CodexBar usage probe failed")
    payload = json.loads(_bounded_output(result.stdout))
    if not isinstance(payload, list) or not payload:
        raise ValueError("CodexBar returned no usage snapshot")
    return payload[0]


def _bounded_output(value, limit=256_000):
    if len(value) > limit:
        raise ValueError("usage probe output exceeded limit")
    return value


def normalize_subscription_usage(payload, provider, model):
    if provider in ("openai", "xai"):
        windows = [
            {
                "id": str(window.get("id") or f"window-{index}"),
                "label": str(window.get("label") or "Usage"),
                "remaining_percent": _remaining_percent(window.get("used_percent")),
                "resets_at": _iso_timestamp(window.get("resets_at")),
                "blocking": True,
            }
            for index, window in enumerate(payload.get("windows") or [])
            if isinstance(window, dict) and _number(window.get("used_percent")) is not None
        ]
        observed_at = _iso_timestamp(payload.get("observed_at"))
        source = payload.get("source")
        plan = payload.get("plan")
    else:
        usage = payload.get("usage") or {}
        plan = usage.get("loginMethod") or (usage.get("identity") or {}).get("loginMethod")
        source = payload.get("source") or "cli"
        observed_at = _iso_timestamp(usage.get("updatedAt"))
        windows = _codexbar_windows(provider, model, usage)

    limited = any(window["blocking"] and window["remaining_percent"] <= 0 for window in windows)
    return {
        "provider": provider,
        "plan": plan,
        "status": "limited" if limited else ("available" if windows else "unknown"),
        "windows": windows,
        "observed_at": observed_at or datetime.now(timezone.utc).isoformat(),
        "source": source,
    }


def _codexbar_windows(provider, model, usage):
    candidates = []
    if provider == "gemini" and usage.get("extraRateWindows"):
        for item in usage["extraRateWindows"]:
            candidates.append((item.get("id"), item.get("title"), item.get("window") or {}))
    else:
        labels = {"primary": "Session", "secondary": "Weekly", "tertiary": "Additional"}
        for key, label in labels.items():
            if isinstance(usage.get(key), dict):
                candidates.append((key, label, usage[key]))
        for item in usage.get("extraRateWindows") or []:
            candidates.append((item.get("id"), item.get("title"), item.get("window") or {}))

    windows = []
    seen = set()
    for index, (window_id, label, window) in enumerate(candidates):
        if not isinstance(window, dict) or _number(window.get("usedPercent")) is None:
            continue
        key = (window_id, window.get("resetsAt"), window.get("usedPercent"))
        if key in seen:
            continue
        seen.add(key)
        windows.append({
            "id": str(window_id or f"window-{index}"),
            "label": str(label or "Usage"),
            "remaining_percent": _remaining_percent(window.get("usedPercent")),
            "resets_at": _iso_timestamp(window.get("resetsAt")),
            "blocking": _window_blocks_model(provider, model, str(label or window_id or "")),
        })
    return windows


def _window_blocks_model(provider, model, label):
    if provider == "gemini":
        is_gemini_model = "gemini" in (model or "").lower()
        is_gemini_window = "gemini" in label.lower()
        return is_gemini_model == is_gemini_window
    if provider != "anthropic":
        return True
    lower = label.lower()
    scoped_models = ("opus", "sonnet", "haiku")
    named_scope = next((name for name in scoped_models if name in lower), None)
    return named_scope is None or named_scope in (model or "").lower()


def _remaining_percent(used_percent):
    return round(max(0.0, min(100.0, 100.0 - float(used_percent))), 2)


def _number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _parse_timestamp(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def _iso_timestamp(value):
    parsed = _parse_timestamp(value)
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z") if parsed else None


def classify_provider_error(response, provider):
    if response.get("status") != "error":
        return None
    diagnostic = "\n".join(
        str(response.get(key) or "")
        for key in ("error", "stderr", "stdout")
    )
    if provider == "gemini":
        diagnostic = "\n".join(
            line for line in diagnostic.splitlines()
            if not re.search(
                r"failed to refresh available models: No credentials found for provider [`']?Gemini[`']?\.",
                line,
                re.IGNORECASE,
            )
        )
    if re.search(
        r"rate.?limit|quota (?:is )?(?:exhausted|reached)|usage limit|too many requests|\b429\b",
        diagnostic,
        re.IGNORECASE,
    ):
        return "subscription_limit"
    if re.search(
        r"unauthori[sz]ed|authentication|auth(?:entication)?[^a-z]+expired|token[^a-z]+expired|"
        r"missing provider credentials|provider auth missing|no (?:usable )?credentials|\b401\b",
        diagnostic,
        re.IGNORECASE,
    ):
        return "auth_expired"
    return None


USAGE_PROBES = {
    "anthropic": probe_claude_usage,
    "gemini": probe_antigravity_usage,
    "openai": probe_chaos_account_usage,
    "xai": probe_chaos_account_usage,
}


def auth_capabilities():
    _require_shim_auth("/auth/capabilities")
    providers = {
        provider: {"api_key": True, "oauth_account": True}
        for provider in OAUTH_ACCOUNT_PROVIDERS
        if provider not in ("anthropic", "gemini")
    }
    providers["anthropic"] = {
        "api_key": True,
        "oauth_account": _claude_supports_subscription_auth(),
        "transport": "clamp",
    }
    providers["gemini"] = {
        "api_key": True,
        "oauth_account": _antigravity_login_available(),
        "transport": "antigravity",
        "experimental": True,
        "provider_policy_risk": True,
    }
    return jsonify({
        "providers": providers,
        "chaos_version": _chaos_version(),
        "claude_version": _claude_version(),
        "antigravity_version": _agy_version(),
    })


def auth_start():
    global _auth_process, _auth_state

    _require_shim_auth("/auth/start")
    provider = _requested_auth_provider()
    credential_before = None
    if provider not in OAUTH_ACCOUNT_PROVIDERS:
        return jsonify({
            "error": f"{provider} does not support subscription account connections in this runtime"
        }), 422

    with _auth_lock:
        if _auth_process is not None and _auth_process.poll() is None:
            return jsonify({"error": "A provider connection is already in progress"}), 409

    # Antigravity opens its normal interactive UI when it is already signed in,
    # rather than emitting another OAuth URL. Confirm the stored credential is
    # actually usable and report it directly instead of starting a stray TUI.
    if provider == "gemini" and _antigravity_oauth_token_fingerprint() is not None:
        existing_status = _antigravity_account_status()
        if existing_status.get("status") == "connected":
            with _auth_lock:
                if _auth_process is not None and _auth_process.poll() is None:
                    return jsonify({
                        "error": "A provider connection is already in progress"
                    }), 409
                _auth_process = None
                _auth_state = existing_status
            return jsonify(existing_status)

    with _auth_lock:
        if _auth_process is not None and _auth_process.poll() is None:
            return jsonify({"error": "A provider connection is already in progress"}), 409

        _auth_code_ready.clear()
        now = datetime.now(timezone.utc)
        _auth_state = {
            "status": "pending",
            "provider": provider,
            "started_at": now.isoformat(),
            "expires_at": (now + timedelta(seconds=AUTH_CODE_TTL_SECS)).isoformat(),
        }
        if provider == "anthropic":
            CLAUDE_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            CLAUDE_CONFIG_DIR.chmod(0o700)
            command = [CLAUDE_BIN, "auth", "login", "--claudeai"]
            auth_env = _anthropic_subscription_env()
            _auth_state["status"] = "starting"
        elif provider == "gemini":
            CHAOS_AGY_HOME.mkdir(parents=True, exist_ok=True)
            CHAOS_AGY_HOME.chmod(0o700)
            _antigravity_login_url_path().unlink(missing_ok=True)
            credential_before = _antigravity_oauth_token_fingerprint()
            command = _antigravity_login_command()
            auth_env = _antigravity_cli_env()
            _auth_state["status"] = "starting"
        else:
            command = [CHAOS_BIN, "--provider", provider, "accounts", "--device-auth"]
            auth_env = _oauth_account_env()
        _auth_process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE if _browser_code_provider(provider) else subprocess.DEVNULL,
            stdout=subprocess.PIPE if _browser_code_provider(provider) else subprocess.DEVNULL,
            stderr=subprocess.STDOUT if _browser_code_provider(provider) else subprocess.PIPE,
            text=True,
            bufsize=1,
            env=auth_env,
        )
        if provider == "gemini":
            threading.Thread(
                target=_advance_antigravity_login,
                args=(_auth_process,),
                daemon=True,
            ).start()
            threading.Thread(
                target=_monitor_antigravity_login_url,
                args=(_auth_process,),
                daemon=True,
            ).start()
            threading.Thread(
                target=_monitor_antigravity_credentials,
                args=(_auth_process, credential_before),
                daemon=True,
            ).start()
        threading.Thread(
            target=_monitor_auth_process,
            args=(_auth_process, provider, credential_before),
            daemon=True,
        ).start()

    _auth_code_ready.wait(timeout=10)
    with _auth_lock:
        expected_status = "awaiting_code" if _browser_code_provider(provider) else "pending"
        # Fresh Antigravity homes sometimes take longer than ten seconds to
        # initialize their browser handoff. Keep the live ceremony polling
        # instead of reporting a terminal provider failure while the process is
        # still legitimately starting.
        if _auth_state.get("status") == "starting":
            return jsonify(_public_auth_state()), 202
        if _auth_state.get("status") != expected_status:
            return jsonify(_public_auth_state()), 502
        if not _auth_state.get("verification_url"):
            return jsonify({"error": "The provider did not provide a sign-in URL"}), 502
        if not _browser_code_provider(provider) and not _auth_state.get("user_code"):
            return jsonify({"error": "Chaos did not provide a device code"}), 502
        response = {
            "status": expected_status,
            "provider": provider,
            "verification_url": _auth_state["verification_url"],
            "expires_in": AUTH_CODE_TTL_SECS,
            "expires_at": _auth_state["expires_at"],
        }
        if not _browser_code_provider(provider):
            response["user_code"] = _auth_state["user_code"]
        return jsonify(response)


def auth_code():
    global _auth_state

    _require_shim_auth("/auth/code")
    payload = request.get_json(silent=True) or {}
    provider = payload.get("provider") or AGENT_PROVIDER
    code = _browser_login_code(payload.get("code"))
    if not _browser_code_provider(provider):
        return jsonify({"error": "This provider does not accept a browser-returned code"}), 422
    if code is None:
        return jsonify({
            "error": "Paste the browser-returned authorization code or callback URL"
        }), 422

    with _auth_lock:
        process = _auth_process
        if process is None or process.poll() is not None or _auth_state.get("status") != "awaiting_code":
            return jsonify({"error": f"No {provider} sign-in is awaiting a code"}), 409
        try:
            # Antigravity runs in a raw PTY and treats Enter as carriage return;
            # a line feed inserts the code without submitting its terminal form.
            terminator = "\r" if provider == "gemini" else "\n"
            process.stdin.write(code + terminator)
            process.stdin.flush()
        except (BrokenPipeError, OSError):
            return jsonify({"error": f"{provider} sign-in stopped before accepting the code"}), 502
        _auth_state["status"] = "finalizing"

    # Never log or retain the one-time code.
    return jsonify({"status": "finalizing", "provider": provider})


def auth_status():
    global _auth_process, _auth_state

    _require_shim_auth("/auth/status")
    provider = _requested_auth_provider()

    with _auth_lock:
        if _auth_process is not None and _auth_process.poll() is None:
            expires_at = datetime.fromisoformat(_auth_state["expires_at"])
            if datetime.now(timezone.utc) >= expires_at:
                process = _auth_process
                _auth_process = None
                process.terminate()
                _auth_state = {
                    "status": "expired",
                    "provider": provider,
                    "message": "The sign-in attempt expired. Start again to get a new link.",
                }
            return jsonify(_public_auth_state())

    return jsonify(_provider_account_status(provider))


def auth_cancel():
    global _auth_process, _auth_state

    _require_shim_auth("/auth/cancel")
    provider = _requested_auth_provider()
    with _auth_lock:
        if _auth_process is not None and _auth_process.poll() is None:
            _auth_process.terminate()
        _auth_process = None
        _auth_state = {"status": "none", "provider": provider}
    log.info(f"provider auth cancelled provider={provider}")
    return jsonify(_public_auth_state())


def auth_disconnect():
    global _auth_process, _auth_state

    _require_shim_auth("/auth/disconnect")
    provider = _requested_auth_provider()
    if provider == "anthropic":
        with _auth_lock:
            if _auth_process is not None and _auth_process.poll() is None:
                _auth_process.terminate()
            _auth_process = None
            _auth_state = {"status": "none", "provider": provider}
        _terminate_claude_clamp_processes()
        _retire_provider_sessions(provider, "provider-disconnected")
        shutil.rmtree(CLAUDE_CONFIG_DIR, ignore_errors=True)
        log.info("provider auth disconnected provider=anthropic")
        return jsonify({"status": "none", "provider": provider})
    if provider == "gemini":
        with _auth_lock:
            if _auth_process is not None and _auth_process.poll() is None:
                _auth_process.terminate()
            _auth_process = None
            _auth_state = {"status": "none", "provider": provider}
        _terminate_antigravity_processes()
        _retire_provider_sessions(provider, "provider-disconnected")
        shutil.rmtree(CHAOS_AGY_HOME, ignore_errors=True)
        log.info("provider auth disconnected provider=gemini")
        return jsonify({"status": "none", "provider": provider})

    result = subprocess.run(
        [CHAOS_BIN, "--provider", provider, "accounts", "disconnect"],
        capture_output=True,
        text=True,
        timeout=20,
        env=_oauth_account_env(),
    )
    if result.returncode != 0:
        return jsonify({
            "error": _tail(result.stderr, 1000) or "Chaos could not disconnect the provider account"
        }), 502
    with _auth_lock:
        _auth_state = {"status": "none", "provider": provider}
    log.info(f"provider auth disconnected provider={provider}")
    return jsonify({"status": "none", "provider": provider})


def _monitor_auth_process(process, provider, credential_before=None):
    global _auth_process, _auth_state

    verification_url = None
    user_code = None
    expecting_code = False
    try:
        output = process.stdout if _browser_code_provider(provider) else process.stderr
        for raw_line in output:
            line = raw_line.strip()
            if not line:
                continue
            if _browser_code_provider(provider):
                url = _first_http_url(line)
                if url and verification_url is None:
                    verification_url = url
                    with _auth_lock:
                        if _auth_process is process:
                            _auth_state["status"] = "awaiting_code"
                            _auth_state["verification_url"] = verification_url
                    _auth_code_ready.set()
                continue
            if "Open this link in your browser" in line:
                continue
            if "one-time code" in line:
                expecting_code = True
                continue
            if verification_url is None:
                match = re.search(r"https?://\S+", line)
                if match:
                    verification_url = match.group(0)
            elif expecting_code and user_code is None:
                user_code = line
                expecting_code = False

            if verification_url and user_code:
                with _auth_lock:
                    if _auth_process is process:
                        _auth_state["verification_url"] = verification_url
                        _auth_state["user_code"] = user_code
                _auth_code_ready.set()

        returncode = process.wait()
        gemini_connected = (
            provider == "gemini"
            and _antigravity_oauth_token_fingerprint() not in (None, credential_before)
        )
        status = _provider_account_status(provider) if returncode == 0 or gemini_connected else {
            "status": "failed",
            "provider": provider,
            "message": "Provider connection was not completed.",
        }
        with _auth_lock:
            if _auth_process is process:
                _auth_state = status
                _auth_process = None
        log.info(f"provider auth finished provider={provider} status={status['status']}")
    except Exception as error:
        with _auth_lock:
            if _auth_process is process:
                _auth_state = {
                    "status": "failed",
                    "provider": provider,
                    "message": str(error),
                }
                _auth_process = None
        log.warning(f"provider auth failed provider={provider}: {error.__class__.__name__}")
    finally:
        _auth_code_ready.set()


def _provider_account_status(provider):
    if provider == "anthropic":
        return _anthropic_account_status()
    if provider == "gemini":
        return _antigravity_account_status()

    result = subprocess.run(
        [CHAOS_BIN, "--provider", provider, "accounts", "status"],
        capture_output=True,
        text=True,
        timeout=10,
        env=_oauth_account_env(),
    )
    output = "\n".join((result.stdout or "", result.stderr or ""))
    provider_line = next(
        (
            line.strip()
            for line in output.splitlines()
            if _line_names_provider(line, provider)
            and ("ChatGPT account" in line or "xAI account" in line)
        ),
        None,
    )
    if not provider_line:
        return {"status": "none", "provider": provider}

    email_match = re.search(r"\(([^()\s]+@[^()\s]+)\)", provider_line)
    response = {"status": "connected", "provider": provider}
    if email_match:
        response["email"] = email_match.group(1)
    return response


def _line_names_provider(line, provider):
    names = {
        "openai": ("openai",),
        "xai": ("xai", "x.ai"),
    }.get(provider, (provider,))
    lowered = line.lower()
    return any(name in lowered for name in names)


def _oauth_account_env():
    OAUTH_CHAOS_HOME.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CHAOS_HOME"] = str(OAUTH_CHAOS_HOME)
    return env


def _anthropic_subscription_env():
    CLAUDE_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CLAUDE_CONFIG_DIR"] = str(CLAUDE_CONFIG_DIR)
    env.pop("ANTHROPIC_API_KEY", None)
    return env


def _antigravity_subscription_env():
    CHAOS_AGY_HOME.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CHAOS_AGY_HOME"] = str(CHAOS_AGY_HOME)
    env["CHAOS_AGY_PATH"] = AGY_BIN
    env.pop("GEMINI_API_KEY", None)
    env.pop("GOOGLE_API_KEY", None)
    return env


def _antigravity_cli_env():
    env = _antigravity_subscription_env()
    env["HOME"] = str(CHAOS_AGY_HOME)
    env["XDG_CONFIG_HOME"] = str(CHAOS_AGY_HOME / ".config")
    env["CHAOS_AGY_LOGIN_URL_PATH"] = str(_antigravity_login_url_path())
    env["PATH"] = os.pathsep.join((
        str(ANTIGRAVITY_BROWSER_HELPER_DIR),
        env.get("PATH", ""),
    ))
    return env


def _antigravity_login_url_path():
    return CHAOS_AGY_HOME / ".login-url"


def _antigravity_oauth_token_path():
    return CHAOS_AGY_HOME / ".gemini" / "antigravity-cli" / "antigravity-oauth-token"


def _antigravity_oauth_token_fingerprint():
    try:
        stat = _antigravity_oauth_token_path().stat()
        return (stat.st_mtime_ns, stat.st_size)
    except FileNotFoundError:
        return None


def _antigravity_login_command():
    # agy's browser login UI is terminal-gated. util-linux script supplies the
    # PTY while preserving pipe-based stdin/stdout for the HTTP ceremony. Turn
    # off terminal echo so the browser-returned authorization code is not copied
    # back into the monitor stream.
    # Launching `models` while signed out exits with an instruction to start the
    # CLI without arguments; the bare invocation enters the browser login flow.
    command = f"stty -echo; exec {shlex.quote(AGY_BIN)}"
    return [SCRIPT_BIN, "-qefc", command, "/dev/null"]


def _advance_antigravity_login(process):
    # The bare CLI opens an onboarding selector before it starts consumer OAuth.
    # The default selection is Google sign-in, so advance that one non-secret UI
    # step after the PTY is ready. Browser consent and the returned code remain
    # user-controlled.
    time.sleep(1)
    if process.poll() is not None:
        return
    try:
        process.stdin.write("\r")
        process.stdin.flush()
    except (BrokenPipeError, OSError):
        pass


def _monitor_antigravity_login_url(process):
    global _auth_state

    path = _antigravity_login_url_path()
    while process.poll() is None:
        try:
            raw_url = path.read_text().strip()
        except FileNotFoundError:
            time.sleep(0.05)
            continue
        path.unlink(missing_ok=True)

        url = _first_http_url(raw_url)
        if url:
            with _auth_lock:
                if _auth_process is process:
                    _auth_state["status"] = "awaiting_code"
                    _auth_state["verification_url"] = url
            _auth_code_ready.set()
            return

        time.sleep(0.05)


def _monitor_antigravity_credentials(process, credential_before):
    # Successful browser sign-in moves Antigravity into its normal interactive
    # TUI instead of exiting. Wait for its token file to finish changing, then
    # stop that TUI so the process monitor can verify and publish the account.
    candidate = None
    stable_since = None
    while process.poll() is None:
        with _auth_lock:
            if _auth_process is not process:
                return
            finalizing = _auth_state.get("status") == "finalizing"

        fingerprint = _antigravity_oauth_token_fingerprint()
        if finalizing and fingerprint not in (None, credential_before):
            if fingerprint != candidate:
                candidate = fingerprint
                stable_since = time.monotonic()
            elif time.monotonic() - stable_since >= 0.2:
                process.terminate()
                return
        else:
            candidate = None
            stable_since = None
        time.sleep(0.05)


def _browser_code_provider(provider):
    return provider in ("anthropic", "gemini")


def _browser_login_code(value):
    raw = str(value or "").strip()
    if not raw or len(raw) > 4096:
        return None

    if raw.startswith(("http://", "https://")):
        parsed = urlparse(raw)
        code = parse_qs(parsed.query).get("code", [None])[0]
        if not code:
            return None
        raw = code.strip()

    if not raw or len(raw) > 4096 or any(character.isspace() for character in raw):
        return None
    return raw


def _first_http_url(line):
    # Claude Code uses OSC-8 terminal hyperlinks on a TTY. Stop at all control
    # characters so the hidden hyperlink target cannot absorb the visible URL.
    match = re.search(r"https?://[^\s\x00-\x1f\x7f]+", line)
    return match.group(0).rstrip(".,)") if match else None


def _anthropic_account_status():
    if not _claude_available():
        return {"status": "none", "provider": "anthropic"}
    result = subprocess.run(
        [CLAUDE_BIN, "auth", "status", "--json"],
        capture_output=True,
        text=True,
        timeout=10,
        env=_anthropic_subscription_env(),
    )
    metadata = {}
    try:
        metadata = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        pass
    connected = result.returncode == 0 and (
        metadata.get("loggedIn") is True
        or metadata.get("logged_in") is True
    )
    if not connected:
        return {"status": "none", "provider": "anthropic"}
    response = {"status": "connected", "provider": "anthropic"}
    email = metadata.get("email") or metadata.get("accountEmail")
    plan = metadata.get("subscriptionType") or metadata.get("plan")
    if email:
        response["email"] = email
    if plan:
        response["plan"] = plan
    return response


def _antigravity_account_status():
    if not _agy_available():
        return {"status": "none", "provider": "gemini"}
    try:
        result = subprocess.run(
            [AGY_BIN, "models"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            env=_antigravity_cli_env(),
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"status": "none", "provider": "gemini"}
    output = "\n".join((result.stdout or "", result.stderr or "")).lower()
    if result.returncode != 0 or "authentication required" in output:
        return {"status": "none", "provider": "gemini"}
    return {"status": "connected", "provider": "gemini", "plan": "Google AI"}


def _retire_provider_sessions(provider, reason):
    if not SESSION_MAP_DIR.exists():
        return
    for path in SESSION_MAP_DIR.glob("*.json"):
        try:
            record = json.loads(path.read_text())
            if record.get("provider") != provider or record.get("auth_mode") != "oauth_account":
                continue
            path.rename(path.with_suffix(f".retired-{reason}.json"))
        except Exception as error:
            log.warning(f"could not retire provider session {path}: {error.__class__.__name__}")


def _terminate_claude_clamp_processes():
    # Each container belongs to one resident, so terminating its clamp workers
    # cannot affect another resident or the host's interactive Claude process.
    subprocess.run(
        ["pkill", "-f", "claude --output-format stream-json"],
        capture_output=True,
        text=True,
        timeout=5,
    )


def _terminate_antigravity_processes():
    subprocess.run(
        ["pkill", "-f", AGY_BIN],
        capture_output=True,
        text=True,
        timeout=5,
    )


def _claude_available():
    return Path(CLAUDE_BIN).exists() or shutil.which(CLAUDE_BIN) is not None


def _claude_supports_subscription_auth():
    if not _claude_available():
        return False
    try:
        result = subprocess.run(
            [CLAUDE_BIN, "auth", "login", "--help"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0 and "--claudeai" in (result.stdout or result.stderr or "")
    except Exception:
        return False


def _claude_version():
    if not _claude_available():
        return None
    try:
        out = subprocess.run([CLAUDE_BIN, "--version"], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or out.stderr.strip() or "unknown"
    except Exception:
        return "unknown"


def _agy_available():
    return Path(AGY_BIN).exists() or shutil.which(AGY_BIN) is not None


def _antigravity_login_available():
    script_available = Path(SCRIPT_BIN).exists() or shutil.which(SCRIPT_BIN) is not None
    return _agy_available() and script_available


def _agy_version():
    if not _agy_available():
        return None
    try:
        out = subprocess.run([AGY_BIN, "--version"], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or out.stderr.strip() or "unknown"
    except Exception:
        return "unknown"


def _public_auth_state():
    return {
        key: value
        for key, value in _auth_state.items()
        # The verification URL is required while the browser ceremony is live:
        # a slow start may first reach the UI through status polling. The
        # provider's one-time device code remains confined to the initial start
        # response.
        if key != "user_code"
    }


def _chaos_version() -> str:
    try:
        out = subprocess.run([CHAOS_BIN, "--version"], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or "unknown"
    except Exception as e:
        return f"error: {e}"


if app:
    app.get("/health")(health)
    app.post("/trigger")(trigger)
    app.get("/auth/capabilities")(auth_capabilities)
    app.get("/auth/usage")(auth_usage)
    app.post("/auth/start")(auth_start)
    app.post("/auth/code")(auth_code)
    app.get("/auth/status")(auth_status)
    app.post("/auth/cancel")(auth_cancel)
    app.post("/auth/disconnect")(auth_disconnect)


if __name__ == "__main__":
    if app is None:
        raise SystemExit("Flask is required to serve trigger_shim.py")

    log.info(f"chaos-agent shim starting: port={SHIM_PORT}, chaos={_chaos_version()}")
    # 0.0.0.0 because we're inside a container; the daemon binds to all interfaces
    # and Docker handles which are externally exposed.
    app.run(host="0.0.0.0", port=SHIM_PORT, debug=False)
