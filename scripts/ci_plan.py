#!/usr/bin/env python3
"""Plan which CI suites to run based on changed repository surfaces.

Fail-safe by design: any unknown path, empty diff, git failure, or manual
workflow_dispatch runs all three suites (application, frontend, runtime).
"""

from __future__ import annotations

import argparse
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys

ALL_SUITES = ("application", "frontend", "runtime")

# Files that cross all three suites (CI config, planner itself, Bun/Vite toolchain).
CROSS_ALL_FILES = frozenset({
    "package.json",
    "bun.lock",
    "config/vite.json",
    "scripts/ci_plan.py",
})

# Frontend-specific config files that affect both Vitest/svelte-size and Vite/Playwright.
FRONTEND_FILES = frozenset({
    "svelte.config.js",
    "vite.config.ts",
    "vite.config.js",
    "vitest.config.js",
    "jsconfig.json",
    "components.json",
    "phosphor_icons_data.json",
})

# Files covered by both Ruby/Rails tests and Python runtime/CI image contracts.
APP_AND_RUNTIME_FILES = frozenset({
    "Gemfile",
    "Gemfile.lock",
    ".ruby-version",
    "mise.toml",
    "Dockerfile",
    "playwright/run-backend.rb",
    "test/fixtures/files/rollback_restic_contract.json",
})

APP_AND_RUNTIME_PREFIXES = (
    "agent-runtime/",
    "host-runner/",
    "services/",
    "ops/deploy/",
    "bin/",
    "script/",
)

APPLICATION_ONLY_FILES = frozenset({
    "config.ru",
    "Rakefile",
    "Procfile.dev",
    "VERSION",
    "playwright-clips.config.js",
    "playwright-ct.config.js",
    "playwright-e2e.config.js",
    "scripts/run-rails-shard.rb",
    "scripts/e2e-shard.mjs",
})

APPLICATION_ONLY_PREFIXES = (
    "app/",
    "config/",
    "db/",
    "lib/",
    "public/",
    "storage/",
    "playwright/",
)

RUNTIME_ONLY_PREFIXES = (
    "ops/",
    "patches/",
    "scripts/",
)

DOCS_ONLY_FILES = frozenset({
    "LICENSE",
})

DOCS_ONLY_PREFIXES = (
    "docs/",
    "research/",
)

RETIRED_DOC_MARKER = "[AGENT-ONLY]"


@dataclass(frozen=True)
class SuitePlan:
    run_application: bool
    run_frontend: bool
    run_runtime: bool
    reason: str

    def as_outputs(self) -> dict[str, str]:
        return {
            "run_application": "true" if self.run_application else "false",
            "run_frontend": "true" if self.run_frontend else "false",
            "run_runtime": "true" if self.run_runtime else "false",
            "reason": self.reason,
        }


def all_suites_plan(reason: str) -> SuitePlan:
    return SuitePlan(
        run_application=True,
        run_frontend=True,
        run_runtime=True,
        reason=reason,
    )


def _normalize(path: str) -> str:
    cleaned = path.strip()
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    return cleaned


def _is_docs_only(path: str) -> bool:
    if path in DOCS_ONLY_FILES:
        return True
    if path.startswith(DOCS_ONLY_PREFIXES):
        return True
    return "/" not in path and path.endswith(".md")


def classify_paths(paths: Iterable[str]) -> SuitePlan:
    """Classify changed repo-relative paths into required CI suites."""
    normalized = [_normalize(p) for p in paths if p and p.strip()]
    if not normalized:
        return all_suites_plan("no changed files detected; running all suites")

    suites = {name: False for name in ALL_SUITES}
    unknown: list[str] = []

    for path in normalized:
        if path.startswith(".github/") or path in CROSS_ALL_FILES:
            return all_suites_plan(f"cross-cutting CI or toolchain file changed: {path}")

        if _is_docs_only(path):
            continue

        if path.startswith("app/frontend/") or path in FRONTEND_FILES:
            suites["application"] = True
            suites["frontend"] = True
            continue

        if path in APP_AND_RUNTIME_FILES or path.startswith(APP_AND_RUNTIME_PREFIXES):
            suites["application"] = True
            suites["runtime"] = True
            continue

        if path in APPLICATION_ONLY_FILES:
            suites["application"] = True
            continue

        if path.startswith("test/"):
            if path.endswith(".py"):
                suites["runtime"] = True
            else:
                suites["application"] = True
            continue

        if path.startswith(APPLICATION_ONLY_PREFIXES):
            suites["application"] = True
            continue

        if path.startswith(RUNTIME_ONLY_PREFIXES):
            suites["runtime"] = True
            continue

        unknown.append(path)

    if unknown:
        return all_suites_plan(f"unclassified path(s) fail safe to all suites: {', '.join(unknown[:3])}")

    enabled = [name for name in ALL_SUITES if suites[name]]
    if not enabled:
        reason = f"docs-only change ({len(normalized)} file(s)); running fast doc contracts only"
    else:
        reason = f"touched surfaces require {', '.join(enabled)} ({len(normalized)} file(s))"

    return SuitePlan(
        run_application=suites["application"],
        run_frontend=suites["frontend"],
        run_runtime=suites["runtime"],
        reason=reason,
    )


def check_doc_contracts(root: Path) -> list[str]:
    """Mirror test/house/telegram_guidance_test.rb so docs-only PRs keep this guard."""
    candidates: list[Path] = []
    agent_docs = root / "agent-runtime" / "docs"
    if agent_docs.is_dir():
        candidates.extend(sorted(agent_docs.rglob("*.md")))
    docs_dir = root / "docs"
    if docs_dir.is_dir():
        for path in sorted(docs_dir.rglob("*.md")):
            if "/.bak/" not in f"/{path.relative_to(root).as_posix()}/":
                candidates.append(path)
    agents_md = root / "AGENTS.md"
    if agents_md.is_file():
        candidates.append(agents_md)

    violations: list[str] = []
    for path in candidates:
        if RETIRED_DOC_MARKER in path.read_text(encoding="utf-8", errors="replace"):
            violations.append(path.relative_to(root).as_posix())
    return violations


def _run_git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )


def changed_paths_for_event(
    root: Path,
    event_name: str,
    before_sha: str | None = None,
    *,
    fetch_master: bool = True,
) -> tuple[list[str] | None, str | None]:
    """Return (paths, fallback_reason). If paths is None, caller should run all suites."""
    if event_name == "workflow_dispatch":
        return None, "workflow_dispatch runs all suites"

    if event_name == "pull_request":
        if fetch_master:
            verify = _run_git(root, "rev-parse", "--verify", "origin/master")
            if verify.returncode != 0:
                _run_git(root, "fetch", "--no-tags", "origin", "+refs/heads/master:refs/remotes/origin/master")
        merge_base = _run_git(root, "merge-base", "origin/master", "HEAD")
        if merge_base.returncode != 0 or not merge_base.stdout.strip():
            return None, "could not compute merge-base against origin/master; running all suites"
        base = merge_base.stdout.strip()
        diff = _run_git(root, "diff", "--name-only", base, "HEAD")
        if diff.returncode != 0:
            return None, "git diff against merge-base failed; running all suites"
        return [line for line in diff.stdout.splitlines() if line.strip()], None

    if event_name == "push":
        if not before_sha or set(before_sha) == {"0"}:
            return None, "push has no previous commit SHA; running all suites"
        verify = _run_git(root, "cat-file", "-e", f"{before_sha}^{{commit}}")
        if verify.returncode != 0:
            return None, "push base commit unavailable locally; running all suites"
        diff = _run_git(root, "diff", "--name-only", before_sha, "HEAD")
        if diff.returncode != 0:
            return None, "git diff for push failed; running all suites"
        return [line for line in diff.stdout.splitlines() if line.strip()], None

    return None, f"unhandled event {event_name!r}; running all suites"


def plan_for_event(
    root: Path,
    event_name: str,
    before_sha: str | None = None,
    *,
    fetch_master: bool = True,
) -> SuitePlan:
    paths, fallback_reason = changed_paths_for_event(
        root,
        event_name,
        before_sha=before_sha,
        fetch_master=fetch_master,
    )
    if paths is None:
        return all_suites_plan(fallback_reason or "fallback to all suites")
    return classify_paths(paths)


def write_github_outputs(output_path: Path, plan: SuitePlan) -> None:
    lines = [f"{key}={value.replace(chr(13), ' ').replace(chr(10), ' ')}" for key, value in plan.as_outputs().items()]
    with output_path.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--event-name", default=None)
    parser.add_argument("--before-sha", default=None)
    parser.add_argument("--github-output", type=Path, default=None)
    parser.add_argument("--no-fetch", action="store_true")
    args = parser.parse_args(argv)

    import os

    event_name = args.event_name if args.event_name is not None else os.environ.get("GITHUB_EVENT_NAME", "")
    before_sha = args.before_sha if args.before_sha is not None else os.environ.get("GITHUB_BEFORE", "")

    violations = check_doc_contracts(args.root)
    if violations:
        print(
            f"Doc contract failed: retired marker {RETIRED_DOC_MARKER!r} found in: {', '.join(violations)}",
            file=sys.stderr,
        )
        return 1

    plan = plan_for_event(
        args.root,
        event_name,
        before_sha=before_sha,
        fetch_master=not args.no_fetch,
    )
    for key, value in plan.as_outputs().items():
        print(f"{key}={value}")

    if args.github_output is not None:
        write_github_outputs(args.github_output, plan)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
