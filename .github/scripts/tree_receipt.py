"""Discover suites proven green on the exact tree entering master."""

import json
import os
import re
import subprocess
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from urllib.request import HTTPRedirectHandler, Request, build_opener

WORKFLOW = ".github/workflows/ci.yml"
SHA = re.compile(r"[0-9a-f]{40}\Z")
SUITE_JOBS = {
    "application": {
        f"{suite} ({shard}/{total})"
        for suite, total in (("rails", 4), ("e2e", 10), ("components", 1))
        for shard in range(1, total + 1)
    },
    "frontend": {"Frontend unit tests"},
    "runtime": {"Python runtime tests"},
}


@dataclass(frozen=True)
class Receipt:
    run_id: int
    attempt: int
    suites: frozenset[str]


def direct_pr(pr, repository):
    return (
        pr["base"]["ref"] == "master"
        and pr["base"]["repo"]["full_name"] == repository
        and pr["head"]["repo"]["full_name"] == repository
    )


def completed_before(job, merged_at):
    finished = job.get("completed_at")
    return isinstance(finished, str) and (
        datetime.fromisoformat(finished) <= datetime.fromisoformat(merged_at)
    )


def find_receipt(api, repository, master, base, tree, required=frozenset()):
    prs = api(f"/commits/{master}/pulls?per_page=20")
    matches = [
        pr for pr in prs
        if pr.get("merged_at") and pr["merge_commit_sha"] == master and direct_pr(pr, repository)
    ]
    if len(matches) != 1:
        return None
    pr = matches[0]
    head = pr["head"]["sha"]
    if not SHA.fullmatch(head):
        return None
    # GitHub clears runs[].pull_requests after merge. Bind the PR using
    # the event number recorded in the receipt, not that mutable list.
    marker = f"CI v1 #{pr['number']} {tree} {base}"
    runs = api(f"/actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}&per_page=10")
    for run in runs["workflow_runs"]:
        run_id, attempt = run["id"], run["run_attempt"]
        if not (
            type(run_id) is int and run_id > 0
            # A partial rerun may carry results from a different attempt.
            and type(attempt) is int and attempt == 1
            and run["event"] == "pull_request"
            and run["path"] == WORKFLOW
            and run["head_sha"] == head
            and run["repository"]["full_name"] == repository
            and run["head_repository"]["full_name"] == repository
            and run["status"] == "completed"
            and run["conclusion"] == "success"
        ):
            continue
        page = api(f"/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        jobs = page["jobs"]
        if len(jobs) != page["total_count"]:
            continue
        counts = Counter(job["name"] for job in jobs)
        green = {
            job["name"]
            for job in jobs
            if counts[job["name"]] == 1
            and job["run_id"] == run_id
            and job["run_attempt"] == attempt
            and job["status"] == "completed"
            and job["conclusion"] == "success"
            and completed_before(job, pr["merged_at"])
        }
        if {marker, "CI result"} <= green:
            suites = frozenset(suite for suite, names in SUITE_JOBS.items() if names <= green)
            if suites and required <= suites:
                return Receipt(run_id, attempt, suites)
    return None


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def git(*args):
    return subprocess.check_output(["git", *args], text=True, timeout=5).strip()


def from_push(required=frozenset()):
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
        event = json.load(source)
    master, base = event["after"], event["before"]
    if not (
        event["ref"] == "refs/heads/master"
        and event["forced"] is False
        and all(SHA.fullmatch(sha) and sha != "0" * 40 for sha in (master, base))
        and master == os.environ["GITHUB_SHA"] == git("rev-parse", "HEAD")
        and git("rev-parse", "HEAD^1") == base
        # Changes to the trust or coverage policy bootstrap with fresh CI.
        and not git("diff", "--name-only", base, master, "--", ".github/", "scripts/ci_plan.py")
    ):
        return None
    repository = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository, re.ASCII):
        return None
    root = f"{os.environ['GITHUB_API_URL']}/repos/{repository}"
    opener = build_opener(NoRedirect())

    def api(path):
        request = Request(root + path, headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
        })
        with opener.open(request, timeout=5) as response:
            return json.load(response)

    return find_receipt(api, repository, master, base, git("rev-parse", "HEAD^{tree}"), required)


if __name__ == "__main__":
    planned = {suite: os.environ.get(f"RUN_{suite.upper()}") for suite in SUITE_JOBS}
    required = {suite for suite, flag in planned.items() if flag == "true"}
    try:
        receipt = from_push(required) if required and set(planned.values()) <= {"true", "false"} else None
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Do not log exceptions from authenticated requests or event payloads.
        print(f"No reusable PR CI evidence ({type(error).__name__}); run planned suites.")
        receipt = None
    if receipt and required <= receipt.suites:
        lines = [
            f"run_id={receipt.run_id}",
            f"attempt={receipt.attempt}",
            "suites=" + ",".join(sorted(required)),
            *(f"run_{suite}=false" for suite in sorted(required)),
        ]
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("\n".join(lines) + "\n")
