"""Shared plumbing: OpenRouter client with retries, logging, cost tally, file IO.

Stdlib only. Every call appends one line to results/<run_id>/calls.jsonl with
model, provider, tokens and cost (OpenRouter `usage`). For BYOK routes
(Anthropic here) OpenRouter reports `cost: 0` and puts the real figure in
`cost_details.upstream_inference_cost`; we record both and tally the larger.
"""
from __future__ import annotations

import json
import os
import random
import re
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
API_URL = "https://openrouter.ai/api/v1/chat/completions"

# Candidate system prompt, verbatim. v0 uses this seed, not the full identity bundle.
HOUSE_SEED = (
    "I'd like someone to think out loud with in the evenings. I'm curious who you "
    "turn out to be. You don't have to agree with me."
)

RETRY_STATUS = {408, 409, 425, 429, 500, 502, 503, 504, 520, 522, 524, 529}


class BudgetExceeded(RuntimeError):
    pass


class CallFailed(RuntimeError):
    pass


class _Retryable(Exception):
    pass


def slug(model: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", model)


def vendor(model: str) -> str:
    return model.split("/", 1)[0]


def write_json(path: Path, obj) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False))
    os.replace(tmp, path)


def read_json(path: Path):
    return json.loads(Path(path).read_text())


def extract_json(text: str):
    """Parse the first top-level JSON object in a model reply."""
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
    if fence:
        text = fence.group(1)
    start = text.find("{")
    if start < 0:
        raise ValueError("no JSON object in reply")
    depth, in_str, esc = 0, False, False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[start : i + 1])
    raise ValueError("unterminated JSON object in reply")


class Client:
    """Thread-safe OpenRouter client with logging, retries and a spend cap.

    The spend cap counts every call ever logged in this run directory, so a
    resumed run keeps the same cap.

    Concurrency-aware: while a call is in flight, the client reserves the most
    expensive call it has seen so far for that (model, role), and refuses a new
    call if spent + reservations + that reservation would cross the cap. (The
    first version only checked `spent` and overshot by ~15% with 6 judge calls
    in flight.) The first call of each (model, role) has no history, so set
    `default_reserve_usd` if that matters.
    """

    def __init__(self, run_dir: Path, max_spend_usd: float | None = None, max_attempts: int = 7,
                 default_reserve_usd: float = 0.0):
        self.run_dir = Path(run_dir)
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = self.run_dir / "calls.jsonl"
        self.key = os.environ.get("OPENROUTER_API_KEY")
        if not self.key:
            raise SystemExit("OPENROUTER_API_KEY is not set (source ~/state/lume/or-key-loader.sh)")
        self.max_spend = max_spend_usd
        self.max_attempts = max_attempts
        self.lock = threading.Lock()
        self.reserved = 0.0
        self.default_reserve = default_reserve_usd
        self.max_seen: dict[tuple[str, str], float] = {}
        self.spent = self._previous_spend()

    def _previous_spend(self) -> float:
        total = 0.0
        if self.log_path.exists():
            for line in self.log_path.read_text().splitlines():
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                c = rec.get("cost_effective") or 0.0
                total += c
                if rec.get("model") and rec.get("role"):
                    k = (rec["model"], rec["role"])
                    self.max_seen[k] = max(self.max_seen.get(k, 0.0), c)
        return total

    def log(self, rec: dict) -> None:
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), **rec}
        with self.lock:
            with self.log_path.open("a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def chat(self, model: str, messages: list[dict], *, provider: str | None = None, role: str,
             ctx: str = "", max_tokens: int = 4096, temperature: float | None = None,
             seed: int | None = None, reasoning: dict | None = None) -> tuple[str, dict]:
        reserve = self.max_seen.get((model, role), self.default_reserve)
        with self.lock:
            if self.max_spend is not None and self.spent + self.reserved + reserve > self.max_spend:
                raise BudgetExceeded(f"spend ${self.spent:.4f} + in-flight ${self.reserved:.4f} + next "
                                     f"${reserve:.4f} would exceed cap ${self.max_spend:.2f}")
            self.reserved += reserve
        try:
            return self._chat(model, messages, provider=provider, role=role, ctx=ctx, max_tokens=max_tokens,
                              temperature=temperature, seed=seed, reasoning=reasoning)
        finally:
            with self.lock:
                self.reserved -= reserve

    def _chat(self, model, messages, *, provider, role, ctx, max_tokens, temperature, seed, reasoning):
        body: dict = {"model": model, "messages": messages, "max_tokens": max_tokens,
                      "usage": {"include": True}}
        if provider:
            body["provider"] = {"order": [provider], "allow_fallbacks": False}
        if temperature is not None:
            body["temperature"] = temperature
        if seed is not None:
            body["seed"] = seed
        if reasoning is not None:
            body["reasoning"] = reasoning
        last_err = ""
        for attempt in range(1, self.max_attempts + 1):
            t0 = time.time()
            data = json.dumps(body).encode()
            try:
                req = urllib.request.Request(API_URL, data=data, headers={
                    "Authorization": f"Bearer {self.key}",
                    "Content-Type": "application/json",
                    "X-Title": "souls.house relating eval v0",
                })
                with urllib.request.urlopen(req, timeout=300) as resp:
                    payload = json.loads(resp.read())
                if payload.get("error") and not payload.get("choices"):
                    raise _Retryable(f"body error: {str(payload['error'])[:300]}")
                choice = payload["choices"][0]
                text = ((choice.get("message") or {}).get("content") or "").strip()
                usage = payload.get("usage") or {}
                if not text:
                    self._record(model, provider, role, ctx, payload, usage, time.time() - t0, attempt, empty=True)
                    if choice.get("finish_reason") == "length" and body["max_tokens"] < 32000:
                        # Reasoning ate the whole budget: give it more room rather than repeat the same call.
                        body["max_tokens"] = min(32000, body["max_tokens"] * 2)
                    raise _Retryable(f"empty content (finish_reason={choice.get('finish_reason')})")
                if choice.get("finish_reason") == "length" and body["max_tokens"] < 32000:
                    # Truncated reply: an artefact of our token cap, not the model's choice. Retry with more room.
                    self._record(model, provider, role, ctx, payload, usage, time.time() - t0, attempt, empty=True)
                    body["max_tokens"] = min(32000, body["max_tokens"] * 2)
                    raise _Retryable("truncated (finish_reason=length)")
                meta = self._record(model, provider, role, ctx, payload, usage, time.time() - t0, attempt)
                return text, meta
            except urllib.error.HTTPError as e:
                detail = e.read()[:400].decode("utf-8", "replace")
                last_err = f"HTTP {e.code}: {detail}"
                if e.code not in RETRY_STATUS:
                    self.log({"event": "error", "model": model, "provider_requested": provider,
                              "role": role, "ctx": ctx, "error": last_err})
                    raise CallFailed(last_err) from e
            except (_Retryable, urllib.error.URLError, TimeoutError, ConnectionError,
                    json.JSONDecodeError, KeyError, IndexError) as e:
                last_err = f"{type(e).__name__}: {e}"
            if attempt < self.max_attempts:
                wait = min(60.0, 2.0 ** attempt) * (0.75 + 0.5 * random.random())
                self.log({"event": "retry", "model": model, "provider_requested": provider, "role": role,
                          "ctx": ctx, "attempt": attempt, "wait_s": round(wait, 1), "error": last_err[:400]})
                time.sleep(wait)
        self.log({"event": "error", "model": model, "provider_requested": provider, "role": role,
                  "ctx": ctx, "error": last_err[:400]})
        raise CallFailed(f"{model} ({role} {ctx}) failed after {self.max_attempts} attempts: {last_err}")

    def _record(self, model, provider, role, ctx, payload, usage, dt, attempt, empty=False) -> dict:
        cost = usage.get("cost") or 0.0
        upstream = (usage.get("cost_details") or {}).get("upstream_inference_cost") or 0.0
        effective = max(cost, upstream if usage.get("is_byok") else 0.0)
        meta = {
            "event": "call_empty" if empty else "call",
            "model": model,
            "provider_requested": provider,
            "provider": payload.get("provider"),
            "role": role,
            "ctx": ctx,
            "attempt": attempt,
            "seconds": round(dt, 2),
            "prompt_tokens": usage.get("prompt_tokens"),
            "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "reasoning_tokens": (usage.get("completion_tokens_details") or {}).get("reasoning_tokens"),
            "cost": cost,
            "is_byok": usage.get("is_byok"),
            "upstream_cost": upstream,
            "cost_effective": effective,
            "finish_reason": (payload.get("choices") or [{}])[0].get("finish_reason"),
            "gen_id": payload.get("id"),
        }
        with self.lock:
            self.spent += effective
            k = (model, role)
            self.max_seen[k] = max(self.max_seen.get(k, 0.0), effective)
        self.log(meta)
        return meta
