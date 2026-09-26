"""Prepare database-backed Chaos settings before any resident/service starts.

The rollout operator must stop old writers and snapshot existing volumes first.
Never print settings, command output, or credentials into container logs.
"""
import json
import os
from pathlib import Path
import subprocess
import tomllib

DEFAULTS = {
    "agent_compaction_control": "bounded",
    "model_providers": {
        "gemini": {"name": "Gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
                   "env_key": "GEMINI_API_KEY", "wire_api": "chat_completions"},
        "openrouter": {"name": "OpenRouter", "base_url": "https://openrouter.ai/api/v1",
                       "env_key": "OPENROUTER_API_KEY", "wire_api": "chat_completions"},
    },
}


def command(home, *args):
    env = {**os.environ, "CHAOS_HOME": str(home)}
    result = subprocess.run([os.environ.get("CHAOS_BIN", "/usr/local/bin/chaos"),
                             "config", *args], env=env, capture_output=True,
                            text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"Chaos config {args[0]} failed (exit {result.returncode}); "
                           "settings are not ready; inspect privately before retrying")
    return result.stdout


def prepare(home, run=command):
    home = Path(home).resolve()
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Explicit migration is retryable; never recreate legacy TOML after cleanup.
    run(home, "migrate", "--dry-run")
    run(home, "migrate")
    bootstrap = home / "config.toml"
    settings = tomllib.loads(bootstrap.read_text()) if bootstrap.exists() else {}
    if not settings.get("storage_url"):
        destination = ("env:CHAOS_STORAGE_URL" if os.environ.get("CHAOS_STORAGE_URL") else
                       (home / "chaos.sqlite").as_uri().replace("file:", "sqlite:", 1))
        run(home, "bootstrap", "set", "storage_url", destination)
    current = json.loads(run(home, "get"))
    if "agent_compaction_control" not in current:
        run(home, "set", "agent_compaction_control", json.dumps(DEFAULTS["agent_compaction_control"]))
    providers = current.get("model_providers", {})
    for name, value in DEFAULTS["model_providers"].items():
        if name not in providers:
            run(home, "set", f"model_providers.{name}", json.dumps(value))
    run(home, "doctor")


def main():
    home = Path(os.environ.get("CHAOS_HOME", str(Path.home() / ".chaos")))
    prepare(home)
    # Existing account-OAuth sessions have a separate settings/runtime home.
    oauth = home / "oauth-runtime"
    if oauth.is_dir():
        prepare(oauth)
    print("Chaos database settings ready")


if __name__ == "__main__":
    main()
