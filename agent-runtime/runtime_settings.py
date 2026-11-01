"""Prepare database-backed Chaos settings before any resident/service starts.

The rollout operator must stop old writers and snapshot existing volumes first.
Legacy OS-keyring credentials must be migrated by the operator on their original
host; do not call migrate-secrets unconditionally in headless containers.
Never print settings, command output, or credentials into container logs.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib

DEFAULTS = {
    "agent_compaction_control": "bounded",
    # Absolute tokens. Chaos uses min(this, 0.9 x the turn's own model window)
    # whenever that window is known (ModelInfo::auto_compact_token_limit), so a
    # home that later switches to a smaller-window model compacts at 90% of the
    # smaller window, not here. With no known window Chaos's default is no
    # limit at all, so this is never later than the default.
    "model_auto_compact_token_limit": 400_000,
    "model_providers": {
        "gemini": {"name": "Gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
                   "env_key": "GEMINI_API_KEY", "wire_api": "chat_completions"},
        "openrouter": {"name": "OpenRouter", "base_url": "https://openrouter.ai/api/v1",
                       "env_key": "OPENROUTER_API_KEY", "wire_api": "chat_completions"},
    },
}

# Identity text Chaos snapshots at session start and restores verbatim after
# every compaction. Hook output (the wake) is lost on compaction; these files
# are what survives it.
HOUSE_PROTECTED_FILES = ("soul.md", "self-narrative.md")
IMPORTED_ROOT_ENV = {"mira_v1": "MIRA_ROOT", "portable_v1": "SOULSHOUSE_HOME_ROOT"}


def _inside(root, relative):
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        return None
    path = (root / relative).resolve()
    return path if path.is_relative_to(root) else None


def protected_files(report=lambda reason: print(
        f"Protected context default not written: {reason}", file=sys.stderr)):
    """The resident's identity files, resolved from its own home.

    House homes: identity/soul.md and identity/self-narrative.md. Imported
    homes: the manifest's `protected_context` list if it declares one (an
    empty list protects nothing), else its `soul` and `narrative`. Files that
    are missing at session start are reported by Chaos as warnings, never
    counted as protected. Returns None when the home cannot be resolved, so
    the key stays absent rather than holding a guess, and reports why in
    metadata only (no paths, no manifest text). A declared [] is a quiet
    opt-out.
    """
    profile = os.environ.get("SOULSHOUSE_HOME_PROFILE") or "house"
    if profile == "house":
        identity = Path(os.environ.get("AGENT_IDENTITY_PATH", "/home/agent/identity"))
        return [str(identity / name) for name in HOUSE_PROTECTED_FILES]
    root_env = IMPORTED_ROOT_ENV.get(profile)
    if not root_env or not os.environ.get(root_env):
        report(f"profile {profile!r} has no home root")
        return None
    root = Path(os.environ[root_env]).resolve()
    try:
        manifest = json.loads((root / "resident-home.json").read_text())
    except (OSError, ValueError):
        report("the home manifest could not be read")
        return None
    declared = manifest.get("protected_context")
    key = "protected_context"
    if declared is None:
        key = "soul/narrative"
        declared = [manifest.get("soul"), manifest.get("narrative")]
    if not isinstance(declared, list):
        report(f"manifest {key} is not a list")
        return None
    resolved = [_inside(root, relative) for relative in declared]
    refused = [i for i, path in enumerate(resolved) if path is None]
    if refused:
        report(f"manifest {key} entries {refused} are not paths inside the home root")
        return None
    return [str(path) for path in resolved]


def command(home, *args):
    env = {**os.environ, "CHAOS_HOME": str(home)}
    result = subprocess.run([os.environ.get("CHAOS_BIN", "/usr/local/bin/chaos"),
                             "config", *args], env=env, capture_output=True,
                            text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"Chaos config {args[0]} failed (exit {result.returncode}); "
                           "settings are not ready; inspect privately before retrying")
    return result.stdout


def offers_migrate(home, run):
    return any(line.split()[:1] == ["migrate"] for line in run(home, "--help").splitlines())


def prepare(home, run=command):
    home = Path(home).resolve()
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Explicit migration is retryable; never recreate legacy TOML after cleanup.
    # Chaos removed `config migrate` with its TOML layers (seuros/chaos#110);
    # only binaries that still offer it have legacy files left to import.
    if offers_migrate(home, run):
        run(home, "migrate", "--dry-run")
        run(home, "migrate")
    bootstrap = home / "config.toml"
    try:
        settings = tomllib.loads(bootstrap.read_text()) if bootstrap.exists() else {}
    except tomllib.TOMLDecodeError:
        # Never overwrite a bootstrap file we cannot read; an operator must look.
        raise RuntimeError("Chaos bootstrap config is unreadable; settings are not ready; "
                           "inspect privately before retrying") from None
    if not settings.get("storage_url"):
        destination = ("env:CHAOS_STORAGE_URL" if os.environ.get("CHAOS_STORAGE_URL") else
                       (home / "chaos.sqlite").as_uri().replace("file:", "sqlite:", 1))
        run(home, "bootstrap", "set", "storage_url", destination)
    current = json.loads(run(home, "get"))
    if "agent_compaction_control" not in current:
        run(home, "set", "agent_compaction_control", json.dumps(DEFAULTS["agent_compaction_control"]))
    # Absent only: an explicit resident value, including an empty protected
    # list, is a choice and is never overwritten.
    if "model_auto_compact_token_limit" not in current:
        run(home, "set", "model_auto_compact_token_limit",
            json.dumps(DEFAULTS["model_auto_compact_token_limit"]))
    if "protected_context_files" not in current:
        files = protected_files()
        if files is not None:
            run(home, "set", "protected_context_files", json.dumps(files))
    if "hook_approval_policy" not in current:
        run(home, "set", "hook_approval_policy", json.dumps("automatic"))
    providers = current.get("model_providers", {})
    for name, value in DEFAULTS["model_providers"].items():
        if name not in providers:
            run(home, "set", f"model_providers.{name}", json.dumps(value))
    app_url = os.environ.get("SOULSHOUSE_APP_URL") or os.environ.get("HELIXKIT_APP_URL")
    if app_url:
        # Scoped resident bearer only. The house upstream key never enters a home.
        run(home, "set", "model_providers.house", json.dumps({
            "name": "On the house", "base_url": app_url.rstrip("/") + "/api/v1/house_inference",
            "env_key": "SOULSHOUSE_BEARER_TOKEN", "wire_api": "chat_completions",
        }))
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
