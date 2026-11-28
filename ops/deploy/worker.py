#!/usr/bin/python3
"""Host-owned worker. Raw subprocess output never crosses the SSH boundary."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

from gate import ROOT, OPERATIONS, TERMINAL, atomic, exited

CONFIG = Path("/etc/house-deploy")
CODE = Path("/opt/house-deploy")
SHA = re.compile(r"[0-9a-f]{40}")
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")
# Host residents a Rebuild found busy. The run records them here and ends; the
# minute timer (`worker.py sweep`) rolls each one in the first minute it is
# idle, so a resident who is busy for hours still moves the same day.
def pending_rolls():
    return ROOT / "pending-rolls.json"


def queue_held():
    """The sweep queue holds a failed roll or alias tag (gate.held_queue, read
    again here under the deployment lock: the gate may have admitted a rebuild
    while the queue was busy-only, and a sweep can hold a roll before that
    rebuild gets the lock)."""
    path = pending_rolls()
    if not path.exists():
        return False
    queue = json.loads(path.read_text())
    return bool(queue.get("held") or queue.get("births_alias_failed"))


# What a merge must change for residents to need a new image: the image's
# whole build context. Anything else ships with Rails alone.
RUNTIME_PATHS = ("agent-runtime",)


def runtime_source():
    """The souls-house commit the residents' current image was built from.

    Written by every runtime build once the image has passed its checks. For
    hosts that built before this file existed, the newest runtime-building run
    that got as far as checking its image (chaos_version on its receipt)."""
    path = ROOT / "runtime-source.json"
    if path.exists():
        revision = json.loads(path.read_text()).get("rails_revision") or ""
        return revision if SHA.fullmatch(revision) else None
    newest = None
    for status in (ROOT / "runs").glob("*/status.json"):
        try:
            data = json.loads(status.read_text())
        except (OSError, ValueError):
            continue
        revision = data.get("rails_revision") or ""
        if (data.get("operation") in ("runtime", "chaos", "both") and data.get("chaos_version")
                and data.get("state") in ("success", "partial") and SHA.fullmatch(revision)):
            mtime = status.stat().st_mtime
            if newest is None or mtime > newest[0]:
                newest = (mtime, revision)
    return newest[1] if newest else None


def mounted_sources():
    """Every host path bind-mounted into a container on this host, running or
    stopped, or None when Docker doesn't give a clean answer. A container
    whose client timed out (Kamal, the runtime check) can outlive the run
    that started it, still holding its clone (Mira, #1080)."""
    try:
        ids = subprocess.run(["docker", "ps", "-aq", "--no-trunc"], capture_output=True,
                             text=True, timeout=60)
        if ids.returncode:
            return None
        names = ids.stdout.split()
        if not names:
            return set()
        mounts = subprocess.run(["docker", "inspect", "--format",
                                 "{{range .Mounts}}{{println .Source}}{{end}}", *names],
                                capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if mounts.returncode:
        # Also when a container went between the two calls: ask next time.
        return None
    return {line.strip() for line in mounts.stdout.splitlines() if line.strip()}


def in_use(repo, mounted):
    path = str(repo)
    return any(source == path or source.startswith(path + "/") for source in mounted)


def remove_checkout(directory, mounted):
    """Delete one run's clone of master (runs/<id>/repo), keeping status.json,
    private.log and every other small file the run wrote. True if it removed
    something. Kept while any container mounts it. A symlink in repo's place
    is unlinked, never followed."""
    repo = directory / "repo"
    if repo.is_symlink():
        repo.unlink()
        return True
    if not repo.exists() or in_use(repo, mounted):
        return False
    shutil.rmtree(repo)
    return True


def latched_runs():
    """The runs current.json and runtime-latch.json name, by id: operation."""
    runs = {}
    for name in ("current.json", "runtime-latch.json"):
        try:
            data = json.loads((ROOT / name).read_text())
            runs[data["id"]] = data["operation"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return runs


def unit_exited(operation):
    try:
        return exited(operation)
    except (OSError, subprocess.SubprocessError):
        return False


def prune_checkouts(mounted=None):
    """Remove the clone from every finished run (#1057).

    Each run clones master into runs/<id>/repo for Kamal and the image builds,
    and nothing reads it once the run has ended: the gate, the sweep and
    runtime_source() read status.json alone. Until 21 Nov 2026 nothing removed
    them (898 runs since 4 Oct, 168 GB). A clone is kept when its run is not
    in a terminal state, when the run is the one current.json or
    runtime-latch.json names and its service hasn't positively exited (the
    gate writes interrupted for a deactivating one too), or when a container
    still mounts it. When Docker can't say, everything is kept. Idempotent; a
    clone that can't be removed is tried again next time. Returns the ids
    whose clone went."""
    mounted = mounted_sources() if mounted is None else mounted
    if mounted is None:
        return []
    latched = latched_runs()
    removed = []
    for status in sorted((ROOT / "runs").glob("*/status.json")):
        directory = status.parent
        if not (directory / "repo").exists() and not (directory / "repo").is_symlink():
            continue
        try:
            state = json.loads(status.read_text()).get("state")
        except (OSError, ValueError):
            continue
        if state not in TERMINAL:
            continue
        if directory.name in latched and not unit_exited(latched[directory.name]):
            continue
        try:
            if remove_checkout(directory, mounted):
                removed.append(directory.name)
        except OSError:
            continue
    return removed


# The two build caches a deploy fills (#1133). Rails images are built by
# Kamal's local BuildKit container, which Kamal creates (and recreates) as
# the builder `kamal-local-docker-container`; its cache lives in that
# container's own state volume, outside the daemon's. Runtime images are
# built by `docker build`, in the daemon's default builder. Neither had a
# limit: on 28 Nov 2026 they held 99.7 GB and 85.4 GB. Kamal's registry
# cache (config/deploy.yml, mode=max) still has every layer, so what the
# limit drops locally is a slower build, never a lost one. BuildKit drops
# the least recently used records first and never one a build is using.
KAMAL_BUILDER = "buildx_buildkit_kamal-local-docker-container0"
BUILD_CACHE_KEEP_GB = 30
# Bounded so a deploy waiting for the lock never waits on a long prune. After
# the first one (by hand: `worker.py prune-caches`), each prune drops about
# one build's worth.
PRUNE_TIMEOUT = 600


def prune_build_caches(keep_gb=BUILD_CACHE_KEEP_GB):
    """Trim both caches to keep_gb each. Only under the deployment lock, so
    no deploy is building. Returns {"default": outcome, "kamal": outcome},
    each "pruned", "failed", or for Kamal's builder "absent" (never created
    on this host, or removed) or "stopped" (BuildKit isn't running to ask)."""
    keep_gb = int(keep_gb)
    if keep_gb < 1:
        raise ValueError("build cache limit must be at least 1 GB")

    def ok(args):
        try:
            return subprocess.run(args, capture_output=True, text=True,
                                  timeout=PRUNE_TIMEOUT).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    outcomes = {"default": "pruned" if ok(["docker", "builder", "prune", "--force",
                                           "--max-used-space", f"{keep_gb}g"]) else "failed"}
    try:
        state = subprocess.run(["docker", "container", "inspect", "--format", "{{.State.Running}}",
                                KAMAL_BUILDER], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        outcomes["kamal"] = "failed"
        return outcomes
    if state.returncode:
        outcomes["kamal"] = "absent" if "No such" in (state.stderr or "") else "failed"
    elif state.stdout.strip() != "true":
        outcomes["kamal"] = "stopped"
    else:
        # buildctl's limit is in MB.
        outcomes["kamal"] = "pruned" if ok(["docker", "exec", KAMAL_BUILDER, "buildctl", "prune",
                                            "--keep-storage", str(keep_gb * 1000)]) else "failed"
    return outcomes


def github(path):
    request = urllib.request.Request("https://api.github.com/repos/seuros/chaos/" + path,
                                     headers={"Accept": "application/vnd.github+json",
                                              "User-Agent": "house-deploy"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def published_revision(releases, reachable):
    """Mainline build assets, not GitHub's older 'latest stable' version tag."""
    for release in sorted(releases, key=lambda r: r.get("published_at") or "", reverse=True):
        tag = release.get("tag_name", "")
        revision = tag.removeprefix("build-")
        if release.get("draft") or not tag.startswith("build-") or not SHA.fullmatch(revision):
            continue
        asset = f"chaos-linux-x86_64-{revision}.tar.gz"
        names = {item["name"] for item in release.get("assets", [])}
        if {asset, asset + ".sha256"} <= names and reachable(revision):
            return revision
    raise RuntimeError("No published mainline Linux runtime")


def roll_in_parallel(items, roll_one, record, *, concurrency, canary=True):
    """Roll residents with one canary first, then the rest at once.

    roll_one(item) returns the roll script's answer (never raises: an error is
    {"result": "unknown"}). record(item, result) is called once per attempt,
    under the caller's own lock if it needs one. With canary, items are tried
    one at a time (stock residents first) until one comes back healthy or
    current on the new image; a busy one is just skipped. Any other answer
    during that phase stops everything: nobody else is touched. After the
    canary, the rest go through a pool of `concurrency` at once, and one
    failure doesn't stop the others (it is held, as before).

    Returns (canary_proven, untouched): untouched are the items never tried
    because the canary failed."""
    remaining = sorted(items, key=lambda item: not item.get("stock", True))
    proven = not canary
    while remaining and not proven:
        item = remaining.pop(0)
        result = roll_one(item)
        record(item, result)
        answer = result.get("result")
        if answer in ("healthy", "current"):
            proven = True
        elif answer != "busy":
            return False, remaining
    if remaining:
        with ThreadPoolExecutor(max_workers=max(1, concurrency)) as pool:
            for item, result in zip(remaining, pool.map(roll_one, remaining)):
                record(item, result)
    return proven, []


def version_tuple(version):
    # ChaOS >= 47.17.0 emits SemVer build metadata (`chaos 47.17.0+<sha>`),
    # replacing the numeric build timestamp (`chaos 47.15.0.<ts>`). Comparing
    # only the numeric prefix means two builds of the same release compare
    # equal, so the version-downgrade guard now only fires across release
    # numbers (same-release ordering needs a commit-ancestry check as a
    # follow-up).
    match = re.fullmatch(r"chaos (\d+(?:\.\d+)+)(?:\+[0-9A-Za-z.-]+)?", version)
    if not match:
        raise RuntimeError("Unrecognised runtime version")
    return tuple(map(int, match[1].split(".")))


def migration_blobs(tree):
    """Compare complete trees, not GitHub compare's first 300 changed files."""
    if tree.get("truncated") is not False:
        raise RuntimeError("Release tree incomplete; operator review required")
    return {entry["path"]: entry["sha"] for entry in tree["tree"]
            if entry["type"] == "blob" and "migrat" in entry["path"].lower()
            and entry["path"].endswith(".sql")}


class MigrationsChanged(RuntimeError):
    def __init__(self, changes):
        super().__init__("Existing runtime migrations changed; operator review required")
        self.changes = changes


def verify_migrations(before, after, accepted=()):
    """Refuse any applied migration that is edited, renamed or deleted upstream,
    unless the owner accepted that exact path at the exact blob residents have."""
    old, new = migration_blobs(before), migration_blobs(after)
    changes = sorted(f"{path}@{sha}" for path, sha in old.items() if new.get(path) != sha)
    refused = [change for change in changes if change not in set(accepted)]
    if refused:
        raise MigrationsChanged(refused)


# Docker's own answer when `docker exec` meets a paused container (#765):
# "Container <name> is paused, unpause the container before exec".
PAUSED_EXEC = re.compile(r"\bis paused, unpause the container before exec\b")


KAMAL_TIMEOUT = 7200
PROBE_TIMEOUT = 300
LOOKUP_TIMEOUT = 30
PROBE_INTERVAL = 15


class BackupsDeferred(RuntimeError):
    """A routine deploy that can't show the house's backups have cleared
    ends here, before the release switch, with nothing deployed: terminal
    state `deferred`, which doesn't latch the next request."""


class ContainerPaused(RuntimeError):
    """The exec failed because the container was paused, by Docker's own
    account of that failure, not by a later look at the container."""


class Worker:
    # Rolls run in threads: status.json, the private log and the sweep queue
    # are written under this one lock.
    lock = threading.RLock()

    def __init__(self, operation):
        self.settings = json.loads((CONFIG / "settings.json").read_text())
        self.data = json.loads((ROOT / "current.json").read_text())
        self.directory = ROOT / "runs" / self.data["id"]
        self.data = json.loads((self.directory / "status.json").read_text())
        if self.data["operation"] != operation or self.data["state"] != "starting":
            raise RuntimeError("No matching request")
        self.log = (self.directory / "private.log").open("a")
        self.repo = self.directory / "repo"

    def report(self, step, **values):
        with self.lock:
            self.data.update(step=step, **values)
            atomic(self.directory / "status.json", self.data)

    def run(self, args, *, input=None, capture=False, timeout=3600, cwd=None, umask=-1):
        result = subprocess.run(args, input=input, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, cwd=cwd, umask=umask)
        with self.lock:
            self.log.write(result.stdout + result.stderr)
            self.log.flush()
        if result.returncode:
            if args[:2] == ["docker", "exec"] and PAUSED_EXEC.search(result.stderr or ""):
                raise ContainerPaused("Container is paused; private diagnostics retained")
            raise RuntimeError("Subprocess failed; private diagnostics retained")
        return result.stdout.strip() if capture else None

    def web(self):
        names = self.run(["docker", "ps", "--filter", "label=service=souls-house",
                          "--filter", "label=role=web", "--format", "{{.Names}}"], capture=True,
                         timeout=LOOKUP_TIMEOUT).splitlines()
        if len(names) != 1:
            raise RuntimeError("Expected exactly one live web container")
        return names[0]

    def rails(self, code, env=None):
        args = ["docker", "exec", "-i"]
        for key, value in (env or {}).items():
            args += ["-e", f"{key}={value}"]
        args += [self.web(), "bin/rails", "runner", "-"]
        output = self.run(args, input=code, capture=True, timeout=PROBE_TIMEOUT)
        return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith("{")))

    def resident_version(self, resident, wait=None):
        """`chaos --version` from a resident container on this host, or None
        when it stayed paused (#765).

        The nightly backup pauses a resident while it copies its home, and
        `docker exec` into a paused container fails. That failure used to end
        the run and latch the runtime, so every later deploy was refused. Now
        a failure Docker itself reports as "is paused" (ContainerPaused, read
        from the failed exec, never from a later look that a backup ending in
        between could falsify) is waited out: try again every 15 s, up to
        `wait` (backup_wait_seconds by default), then None. Any other failure
        raises, as before."""
        if wait is None:
            wait = self.settings.get("backup_wait_seconds", 2400)
        deadline = time.monotonic() + wait
        while True:
            try:
                return self.run(["docker", "exec", resident["container_name"], "chaos", "--version"], capture=True)
            except ContainerPaused:
                pass
            if time.monotonic() >= deadline:
                return None
            self.report("waiting for a resident its backup has paused", waiting_for_paused=resident["id"])
            time.sleep(15)

    def checkout(self):
        self.report("resolving master", state="running")
        self.run(["git", "clone", "--depth", "1", "--single-branch", "--branch", "master",
                  self.settings["repository"], str(self.repo)], umask=0o022)
        # Only public source gets normal file modes. The enclosing run directory,
        # configuration, receipts and logs remain root-private. Docker COPY keeps
        # source modes, so a 077 checkout would break non-root runtime startup.
        revision = self.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture=True)
        if not SHA.fullmatch(revision):
            raise RuntimeError("Invalid master revision")
        expected = self.data.get("expected_revision")
        if expected and revision != expected:
            # Master moved on after the caller checked it. Deploy nothing; the
            # newer commit's own request will deploy it once it has passed CI.
            self.report("master moved on; nothing deployed", state="superseded",
                        rails_revision=revision)
            return
        self.report("master resolved", rails_revision=revision)
        # Kamal executes only after checkout; service scripts remain root-installed
        # and cannot silently change through a web deployment.

    def kamal(self, *args):
        name = "house-deploy-kamal-" + self.data["id"]
        command = [
            "docker", "run", "--rm", "--name", name, "--network", "host",
            "-v", "/var/run/docker.sock:/var/run/docker.sock",
            "-v", f"{self.repo}:/work",
            "-v", f"{CONFIG}/house.env:/work/config/house.env:ro",
            "-v", f"{CONFIG}/secrets:/work/.kamal/secrets:ro",
            "-v", f"{CONFIG}/ssh:/root/.ssh:ro",
            "-v", f"{ROOT}/docker:/root/.docker",
            "-e", "HOUSE_BUILDER_REMOTE=",
            self.settings["tools_image"], *args,
        ]
        try:
            self.run(command, timeout=KAMAL_TIMEOUT)
        except Exception:
            # Killing a docker-run client alone doesn't stop its container.
            # Only this job's explicitly named tools container can be removed.
            try:
                self.run(["docker", "rm", "-f", name], timeout=30)
            except Exception:
                # It may still be switching: the backup fence stays up and
                # expires by itself (Mira, #1096).
                self.kamal_uncertain = True
                raise
            raise

    PROBE_BOUND = LOOKUP_TIMEOUT + PROBE_TIMEOUT

    def fence_ttl(self):
        """The fence must outlast everything this worker can still do before
        jobs stop (Mira, #1096): the wait, one probe overrunning its limit
        (the web lookup and the Rails runner, both bounded) and the sleep
        before it, then Kamal's whole switch, plus a margin. Before the
        switch starts, the time left is checked against Kamal's timeout
        (fence_covers_switch). A worker killed while Kamal's tools container
        keeps running is outside this bound."""
        wait = self.settings.get("backup_wait_seconds", 2400)
        return wait + self.PROBE_BOUND + PROBE_INTERVAL + KAMAL_TIMEOUT + 600

    def fence_covers_switch(self):
        left = self.fence_expires - time.monotonic()
        return left >= KAMAL_TIMEOUT + 300

    def jobs_absent(self):
        """Positive evidence that no backup can be cut off: Docker answered
        and no job worker is running."""
        try:
            names = self.run(["docker", "ps", "--filter", "label=service=souls-house",
                              "--filter", "label=role=jobs", "--format", "{{.Names}}"], capture=True,
                             timeout=LOOKUP_TIMEOUT)
        except Exception:
            return False
        return names.strip() == ""

    def defer(self, why, **values):
        """Ends a routine deploy before the switch, with nothing deployed."""
        kept = {key: value for key, value in values.items() if key not in ("backup_wait", "backups_cut_off")}
        if values.get("backups_cut_off"):
            kept["waiting_for_backups"] = values["backups_cut_off"]
        self.report(f"deferred: {why}; nothing deployed", backup_wait="deferred", **kept)
        raise BackupsDeferred(why)

    def raise_backup_fence(self):
        """While the fence is up no house backup claims or pauses a resident
        (Backup::DeployFence; Mira frozen 04:08-06:50Z on 21 Nov 2026, when a
        release switch stopped the worker holding her pause). Raised before
        the wait, so a backup either claimed first and is waited for, or is
        refused and busy-retried later: the start race between the last
        check and the job worker stopping is closed. A live release with no
        fence at all (the one before it shipped) is deployed with the claim
        wait alone. A fence that a release which has one fails to raise
        defers the deploy, unless no job worker is running."""
        code = ("if defined?(Backup::DeployFence); "
                "Backup::DeployFence.raise!(ENV.fetch('DEPLOY_ID'), ttl: Integer(ENV.fetch('FENCE_TTL')).seconds); "
                "puts({fenced: true}.to_json); else; puts({fenced: false}.to_json); end")
        ttl = self.fence_ttl()
        self.fence_expires = time.monotonic() + ttl
        try:
            answer = self.rails(code, env={"DEPLOY_ID": self.data["id"], "FENCE_TTL": str(ttl)})
        except Exception:
            if self.jobs_absent():
                self.report("backup fence not raised; no job worker running", backup_fence="unraised")
                return False
            self.defer("the backup fence could not be raised", backup_fence="unraised")
            return False
        if not answer.get("fenced"):
            self.report("live release has no backup fence; claim wait only", backup_fence="absent")
            return False
        self.report("backup fence raised", backup_fence="raised")
        return True

    def lower_backup_fence(self):
        code = "Backup::DeployFence.lower!(ENV.fetch('DEPLOY_ID')); puts({lowered: true}.to_json)"
        try:
            self.rails(code, env={"DEPLOY_ID": self.data["id"]})
            outcome = "lowered"
        except Exception:
            outcome = "expires"
        with self.lock:
            self.data["backup_fence"] = outcome
            atomic(self.directory / "status.json", self.data)

    def wait_for_backups(self):
        """A release switch stops the job worker and cuts off any VM thinning,
        VM backup or house backup it is running (a cut house backup leaves
        its resident paused). So the switch waits for them, up to a limit,
        and a routine deploy that can't show they have cleared is deferred
        rather than cutting one off (Mira, #1096): still running at the
        limit, or unreadable while a job worker runs. A house backup counts
        while it holds any pause claim; claims whose heartbeat has gone
        silent are reported as stale, most likely a dead worker's, and are
        for an operator to release by the recovery runbook. How the
        wait ended stays in `backup_wait`, which no later step overwrites."""
        script = (CODE / "backup-in-flight.rb").read_text()
        deadline = time.monotonic() + self.settings.get("backup_wait_seconds", 2400)
        seen, unread, stale = [], 0, []
        while True:
            try:
                busy = self.rails(script)
                residents, unread = sorted(set(busy["thinning"]) | set(busy["backing_up"])), 0
                stale = sorted(busy.get("stale_claims", []))
            except Exception:
                residents, unread = None, unread + 1
            if residents == []:
                self.report("backups idle", backup_wait="waited" if seen else "idle")
                return
            if residents:
                seen = residents
            if residents is None and not seen and unread >= 3:
                if self.jobs_absent():
                    self.report("could not read running backups; no job worker running", backup_wait="unread")
                    return
                self.defer("could not read running backups")
            if time.monotonic() >= deadline:
                self.defer("backups still running at the wait limit" if residents
                           else "backups unreadable at the wait limit",
                           backups_cut_off=seen, stale_pause_claims=stale)
            if residents:
                self.report("waiting for running backups", waiting_for_backups=residents,
                            stale_pause_claims=stale)
            else:
                self.report("could not read running backups; asking again")
            time.sleep(PROBE_INTERVAL)

    def deploy_rails(self):
        self.report("building Rails")
        # Kamal deploy takes its own production deploy lock: Mac/Dell operators
        # contend for the same lock. No separate acquire (that would deadlock it).
        # Built and pushed first, so that the wait below ends a pull and a
        # web boot before the job worker stops, not a whole build before it.
        revision = self.data["rails_revision"]
        self.kamal("build", "push", "--skip-hooks", "--version", revision)
        self.kamal_uncertain = False
        fenced = self.raise_backup_fence()
        try:
            self.wait_for_backups()
            if fenced and not self.fence_covers_switch():
                self.defer("too little backup fence left for the release switch")
            self.report("deploying Rails")
            self.kamal("deploy", "--skip-push", "--skip-hooks", "--version", revision)
        finally:
            if fenced and self.kamal_uncertain:
                with self.lock:
                    self.data["backup_fence"] = "held"
                    atomic(self.directory / "status.json", self.data)
            elif fenced:
                self.lower_backup_fence()
        for role in ("web", "jobs"):
            versions = self.run(["docker", "ps", "--filter", "label=service=souls-house",
                                 "--filter", f"label=role={role}",
                                 "--format", "{{.Names}}"], capture=True).splitlines()
            if versions != [f"souls-house-{role}-{revision}"]:
                raise RuntimeError("Live application revision mismatch")
        self.run(["curl", "--fail", "--silent", "--show-error", "--max-time", "30",
                  self.settings["health_url"]], timeout=40)
        self.rails("RefreshTelegramWebhooksJob.perform_later; puts({ok:true}.to_json)")
        self.report("Rails healthy")

    def check_runtime_change(self):
        """After a Rails deploy: does this commit change the resident image?

        The answer goes on the receipt (runtime_rebuild_needed) and the
        automatic deploy workflow runs Rebuild residents when it is true. This
        never fails the Rails deploy: when the comparison can't be made the
        answer is true, because an extra rebuild only rolls idle residents and
        a missed one leaves them on old code with nobody told."""
        revision = self.data["rails_revision"]
        try:
            source = runtime_source()
        except Exception as error:
            self.log.write(f"\nruntime source: {type(error).__name__}: {error}\n")
            self.log.flush()
            source = None
        if source == revision:
            needed = False
        elif source is None:
            needed = True
        else:
            try:
                self.run(["git", "fetch", "--quiet", "--depth", "1", "origin", source],
                         cwd=self.repo, timeout=300)
                changed = self.run(["git", "diff", "--name-only", source, "HEAD", "--",
                                    *RUNTIME_PATHS], cwd=self.repo, capture=True)
                needed = bool(changed.strip())
            except Exception as error:
                self.log.write(f"\nruntime comparison: {type(error).__name__}: {error}\n")
                self.log.flush()
                needed = True
        self.report("resident image " + ("changed; rebuild needed" if needed else "unchanged"),
                    runtime_rebuild_needed=needed, runtime_source=source)

    def container_exists(self, name):
        result = subprocess.run(["docker", "container", "inspect", "--format", "{{.Id}}", name],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=60)
        self.log.write(result.stdout + result.stderr)
        self.log.flush()
        if result.returncode and "No such container" not in result.stderr:
            raise RuntimeError("Subprocess failed; private diagnostics retained")
        return result.returncode == 0

    def present_residents(self, residents):
        """An inactive agent whose container was never made (or was removed) has
        nothing to roll: leave it alone and say so. Its image tag, if it is a
        stock alias, still moves with the fleet. A missing container on an
        ACTIVE resident is real damage, so that still stops the run.

        A resident on its own VM has its container there, not on this host, so
        it is never probed here or counted as missing. An active one is
        returned separately and rolled through its runner (roll_vm_residents);
        an inactive one (a retired throwaway) is left alone and reported."""
        present, absent, elsewhere, on_vm = [], [], [], []
        for resident in residents:
            if resident.get("on_vm"):
                if resident["active"]:
                    on_vm.append(resident)
                else:
                    elsewhere.append(resident["id"])
            elif self.container_exists(resident["container_name"]):
                present.append(resident)
            elif resident["active"]:
                raise RuntimeError("Active resident has no container; operator review required")
            else:
                absent.append(resident["id"])
        if absent:
            self.report("inactive residents without containers left alone", absent=absent)
        if elsewhere:
            self.report("inactive residents on their own servers left alone", on_vm=elsewhere)
        return present, on_vm

    def inspect_image(self, image):
        return json.loads(self.run(["docker", "image", "inspect", image], capture=True))[0]

    def update_chaos(self):
        self.roll_runtime(pinned=False)

    def rebuild_residents(self):
        """Rebuild resident images from master, keeping the Chaos they already run."""
        self.roll_runtime(pinned=True)

    def roll_runtime(self, pinned):
        revision = None
        if not pinned:
            self.report("resolving published Chaos")
            master = github("commits/master")["sha"]
            revision = published_revision(
                github("releases?per_page=50"),
                lambda sha: github(f"compare/{sha}...{master}")["status"] in ("ahead", "identical"))
            self.report("Chaos resolved", chaos_revision=revision)
        residents = self.rails(
            "raise 'Async admission required' unless ResidentTurn.enabled?; "
            "puts({residents:Agent.hosted.where.not(container_name:[nil,'']).includes(:placement)"
            ".order(:id).map{|a| a.attributes.slice('id','container_name','container_image','active','paused')"
            ".merge('on_vm'=>a.placement&.backend=='hetzner_cloud')}}.to_json)"
        )["residents"]
        residents, vm_residents = self.present_residents(residents)
        if not residents and not vm_residents:
            raise RuntimeError("No resident containers")
        atomic(self.directory / "previous-residents.json", residents + vm_residents)
        previous_refs = set()
        for resident in residents + vm_residents:
            profile = self.settings["custom_residents"].get(str(resident["id"]))
            if profile is not None and resident.get("on_vm"):
                raise RuntimeError("Custom runtime on a VM; operator review required")
            repository = resident["container_image"].rsplit(":", 1)[0]
            if profile != "development" and repository not in self.settings["stock_repositories"]:
                raise RuntimeError("Unrecognised custom image; operator review required")
        # What a VM resident runs is the image its runner last confirmed, not
        # what its tag on this host points at now. One it can't be reached on
        # is skipped, and the run ends partial.
        vm_running, unreachable = [], []
        for resident in vm_residents:
            state = self.rails(self.vm_script(), {"DEPLOY_VM_MODE": "inspect",
                                                  "DEPLOY_RESIDENT_ID": str(resident["id"])})
            if state.get("running") and IMAGE_ID.fullmatch(state.get("image") or ""):
                vm_running.append(dict(resident, running_image=state["image"]))
            else:
                unreachable.append(resident["id"])
        if unreachable:
            self.report("residents on unreachable servers left unchanged", skipped=list(unreachable))
        for resident in residents + vm_running:
            # A VM's running image is still on this host: it was built here and
            # handed over by ID, and deploys never prune.
            info = self.inspect_image(resident.get("running_image") or resident["container_image"])
            before_ref = info["Config"].get("Labels", {}).get("house.souls.chaos-ref", "")
            if not SHA.fullmatch(before_ref):
                raise RuntimeError("Previous runtime has no source label")
            previous_refs.add(before_ref)
        if not previous_refs:
            raise RuntimeError("No reachable residents; operator review required")
        if pinned:
            # Never pick a winner between residents: one running revision or none.
            if len(previous_refs) != 1:
                raise RuntimeError("Residents run different Chaos revisions; operator review required")
            revision = next(iter(previous_refs))
            self.report("Chaos kept", chaos_revision=revision)
        previous_refs.discard(revision)
        target_tree = github(f"git/trees/{revision}?recursive=1") if previous_refs else None
        for old in previous_refs:
            comparison = github(f"compare/{old}...{revision}")
            if comparison["status"] not in ("ahead", "identical"):
                raise RuntimeError("Refusing runtime downgrade or divergent release")
            try:
                verify_migrations(github(f"git/trees/{old}?recursive=1"), target_tree,
                                  self.data.get("accepted_migrations", []))
            except MigrationsChanged as error:
                # Public on purpose: these upstream paths are what the owner reviews
                # and pastes into accept_migrations to let this release through.
                self.report("migrations changed upstream", migration_changes=error.changes)
                raise

        tag = f"deploy-{self.data['id']}"
        stock = self.settings["stock_repository"] + ":" + tag
        self.report("building published runtime image")
        self.run(["docker", "build", "--build-arg", f"CHAOS_HEAD={revision}",
                  "--build-arg", "CHAOS_BUILD_MODE=prebuilt", "-t", stock,
                  str(self.repo / "agent-runtime")], timeout=7200)
        version = self.run(["docker", "run", "--rm", "--network", "none", "--entrypoint",
                            "chaos", stock, "--version"], capture=True)
        version_tuple(version)
        self.report("checking runtime", chaos_version=version)
        self.check_runtime_permissions(stock)
        self.run(["docker", "run", "--rm", "--network", "none",
                  "-v", f"{self.repo}:/source:ro", "-e", "CHAOS_TEST_BIN=/usr/local/bin/chaos",
                  "--entrypoint", "python3", stock, "-m", "unittest", "discover",
                  "-s", "/source/test", "-p", "runtime_config_test.py"], timeout=300)
        # From here on, residents move to this source. A later Rails deploy
        # compares against it to decide whether they need another rebuild. A
        # roll that fails below is held for the operator; rebuilding the same
        # source again would only repeat it.
        if SHA.fullmatch(self.data.get("rails_revision") or ""):
            atomic(ROOT / "runtime-source.json",
                   {"rails_revision": self.data["rails_revision"], "run": self.data["id"]})
        # Residents a backup kept paused past the wait in this run (#765).
        deferred = set()
        if pinned:
            # Same source must give the same binary. Check every resident before
            # touching any, so a mismatch never leaves the fleet half-rolled.
            for resident in residents:
                running = self.resident_version(resident)
                if running is None:
                    # Still paused by its backup: its check is owed, not
                    # skipped. It waits in the queue and the sweep runs the
                    # check before it may be recreated (owed_preflight).
                    deferred.add(resident["id"])
                    continue
                if running != version:
                    raise RuntimeError("Rebuilt Chaos differs from the running one")
            for resident in vm_running:
                if self.image_version(resident["running_image"]) != version:
                    raise RuntimeError("Rebuilt Chaos differs from the running one")
        development = None
        if any(str(r["id"]) in self.settings["custom_residents"] for r in residents):
            development = self.settings["development_repository"] + ":" + tag
            self.report("building development runtime layer")
            self.run(["docker", "build", "--build-arg", f"MIRA_BASE_IMAGE={stock}",
                      "-f", str(self.repo / "agent-runtime/Dockerfile.mira-dev"),
                      "-t", development, str(self.repo / "agent-runtime")], timeout=7200)
            self.check_runtime_permissions(development)
        skipped = list(unreachable)
        # Residents now running the stock image this run built. Births use the
        # stock alias, so it moves once one of them proves the image runs.
        proven = []
        held = []
        # This run covers every resident, so an older run's list is superseded.
        # The intended work is written BEFORE any attempt and checkpointed after
        # each one, so no error later in this run (timeout, probe, VM) can lose
        # a resident the sweep still has to roll.
        # Every entry starts owing its preflight (the pinned equality and the
        # downgrade check, #765); it is cleared below only for a resident
        # whose version this run has read and checked. So a run interrupted
        # anywhere before then leaves the sweep to run the checks itself,
        # never to recreate without them.
        pending = [{"id": r["id"], "stock": str(r["id"]) not in self.settings["custom_residents"],
                    "image": development if str(r["id"]) in self.settings["custom_residents"] else stock,
                    "preflight": {"container_name": r["container_name"], "pinned": pinned}}
                   for r in residents]
        queue = {"run": self.data["id"], "chaos_version": version, "residents": pending,
                 "held": held, "stock_image": stock,
                 # Not ours to roll, but unresolved: the receipt never claims
                 # completion while any of these remain (VM skips, unreachable).
                 "external_skipped": list(unreachable),
                 # The starting image of each VM that passed this run's
                 # preflight (source label, ancestry, migrations, the pinned
                 # version match). The sweep only starts a VM still on exactly
                 # this image; one unreachable here never passed and is left
                 # owed for the next explicit run (#1036).
                 "vm_approved_images": {str(r["id"]): r["running_image"] for r in vm_running},
                 # Set only once the alias tag has actually succeeded.
                 "births_image_moved": False, "births_allowed": True}
        atomic(pending_rolls(), queue)
        script = (CODE / "roll-resident.rb").read_text()
        # Every resident's binary is read before anyone is touched, so a
        # downgrade stops the run with the fleet unchanged.
        old_versions = {}
        for resident in residents:
            if resident["id"] in deferred:
                old_versions[resident["id"]] = None
                continue
            try:
                raw = self.resident_version(resident)
                if raw is None:
                    deferred.add(resident["id"])
                    old_versions[resident["id"]] = None
                    continue
                # Parsed inside the guard: an answer we can't read is an
                # unknown resident (held, never rolled), not an aborted run
                # that leaves the whole queue for the sweep with no hold.
                old = version_tuple(raw)
            except Exception:
                raw, old = None, None
            old_versions[resident["id"]] = raw
            if old is not None and version_tuple(version) < old:
                pending_rolls().unlink(missing_ok=True)
                raise RuntimeError("Refusing runtime version downgrade")
        # Checked here: their preflight is done. A resident still paused by
        # its backup keeps it owed (busy, not held: nothing failed), and so
        # does one whose version couldn't be read (held below anyway).
        for entry in pending:
            if entry["id"] not in deferred and old_versions.get(entry["id"]) is not None:
                entry.pop("preflight")
        atomic(pending_rolls(), queue)
        if deferred:
            self.report("residents paused by their backup will roll when free", deferred=sorted(deferred))

        def roll_one(entry):
            resident_id = entry["id"]
            self.report("rolling resident if idle", resident_id=resident_id)
            if resident_id in deferred:
                # Paused by its backup past the wait: busy, its preflight
                # owed in the queue for the sweep.
                return {"result": "busy"}
            if old_versions.get(resident_id) is None:
                return {"result": "unknown"}
            try:
                return self.rails(script, {
                    "DEPLOY_RESIDENT_ID": str(resident_id),
                    "DEPLOY_RESIDENT_IMAGE": entry["image"], "DEPLOY_CHAOS_VERSION": version})
            except Exception:
                # Outcome unknown (transport, timeout or the roll script).
                # Held, never retried automatically; the others carry on.
                return {"result": "unknown"}

        def record(entry, result):
            resident_id = entry["id"]
            with self.lock:
                if result.get("result") in ("healthy", "current"):
                    pending.remove(entry)
                    atomic(self.directory / f"resident-{resident_id}.json", result)
                    if entry["image"] == stock:
                        proven.append(resident_id)
                    self.report("resident healthy", resident_id=resident_id)
                elif result.get("result") == "busy":
                    skipped.append(resident_id)
                    self.report("busy resident will roll when idle", skipped=list(skipped))
                else:
                    pending.remove(entry)
                    held.append(resident_id)
                    queue["births_allowed"] = False
                atomic(pending_rolls(), queue)

        canary_proven, untouched = roll_in_parallel(
            list(pending), roll_one, record,
            concurrency=self.settings.get("roll_concurrency", 6))
        queue["canary_proven"] = canary_proven
        if untouched:
            # The canary failed: everyone else stays exactly as they were, and
            # nothing is left for the sweep to roll onto a suspect image.
            for entry in untouched:
                pending.remove(entry)
            queue["untouched"] = [e["id"] for e in untouched]
            self.report("canary failed; other residents left untouched", untouched=queue["untouched"])
        atomic(pending_rolls(), queue)
        host_waiting = {e["id"] for e in pending}
        if held:
            queue["external_skipped"] += [r["id"] for r in vm_running]
            atomic(pending_rolls(), queue)
            self.report("resident roll failed; held for operator review", held=held)
            raise RuntimeError("Unexpected restart result")
        if vm_running:
            # VMs a start was sent to, and the command each restart got: a
            # failure below must say which ones are uncertain (#1036).
            touched, started = [], {}
            try:
                self.roll_vm_residents(vm_running, stock, version, skipped, proven,
                                       touched=touched, started=started)
            except Exception:
                # A VM that failed casts doubt on the image: births stay put.
                queue["births_allowed"] = False
                unsettled = [r["id"] for r in vm_running if r["id"] not in proven and r["id"] not in skipped]
                # A VM whose restart failed or never settled is held, with its
                # command, never retried by the sweep; and while anything is
                # held no other owed VM starts. If the failure came before any
                # start (a version read, the image ID), every unsettled VM is
                # held: nothing about this image is proven on a VM.
                failed = [i for i in unsettled if i in touched] or unsettled
                held.extend(failed)
                queue["vm_failed_commands"] = {str(i): started[i] for i in failed if i in started}
                queue["external_skipped"] = [i for i in skipped if i not in host_waiting] + \
                    [i for i in unsettled if i not in failed]
                atomic(pending_rolls(), queue)
                raise
        queue["external_skipped"] = [i for i in skipped if i not in host_waiting]
        atomic(pending_rolls(), queue)
        # A partial run still moves the alias: what was skipped was busy or
        # unreachable, not broken, and new residents (on the host or their own
        # VM) must be born on the Chaos the house is moving to, not on the last
        # run that happened to reach everyone. A failed run never gets here.
        if proven:
            for alias in self.settings["stock_aliases"]:
                self.run(["docker", "tag", stock, alias])
            queue["births_image_moved"] = True
        # A VM resident skipped here (busy or unreachable) is still owed the
        # image: the queue stays, and the minute sweep retries it. Until #1029
        # (19 Nov 2026) a run with no host resident left waiting deleted the
        # file and with it the skip (Alanis, 17 Nov, run d948d4dc).
        if pending or queue["external_skipped"]:
            atomic(pending_rolls(), queue)
        else:
            pending_rolls().unlink(missing_ok=True)
        if skipped:
            self.report("runtime rollout incomplete", state="partial", skipped=skipped,
                        births_image_moved=bool(proven),
                        # The host residents the minute sweep will still roll.
                        # When skipped is exactly these, nothing is stuck.
                        waiting=[e["id"] for e in pending])
            return
        if not proven:
            # Only custom residents moved: the stock image never ran as one.
            self.report("all residents healthy", births_image_moved=False)
            return
        self.report("all residents healthy")

    def vm_script(self):
        return (CODE / "roll-vm-resident.rb").read_text()

    def image_version(self, image):
        return self.run(["docker", "run", "--rm", "--network", "none", "--entrypoint",
                         "chaos", image, "--version"], capture=True)

    def roll_vm_residents(self, vm_running, stock, version, skipped, proven, touched=None, started=None):
        """Each VM gets the stock image this run built and checked, by image ID,
        through the same restart its runner does for new credentials. Turns
        are held from the moment the start is queued until the runner confirms
        that exact image. A failed restart keeps the hold and stops the run.
        touched collects the VMs a start was sent to, started the command ID
        of each restart that was queued."""
        touched = [] if touched is None else touched
        started = {} if started is None else started
        target_id = self.run(["docker", "image", "inspect", "--format", "{{.Id}}", stock],
                             capture=True)
        if not IMAGE_ID.fullmatch(target_id):
            raise RuntimeError("Built image has no image ID")
        script = self.vm_script()
        # Checked for all before any restart, so a downgrade touches nobody.
        for resident in vm_running:
            if version_tuple(version) < version_tuple(self.image_version(resident["running_image"])):
                raise RuntimeError("Refusing runtime version downgrade")

        def roll_one(resident):
            resident_id = resident["id"]
            self.report("waiting for idle resident", resident_id=resident_id)
            deadline = time.monotonic() + self.settings.get("idle_wait_seconds", 600)
            with self.lock:
                touched.append(resident_id)
            while True:
                result = self.rails(script, {
                    "DEPLOY_VM_MODE": "start", "DEPLOY_RESIDENT_ID": str(resident_id),
                    "DEPLOY_RESIDENT_IMAGE": stock, "DEPLOY_RESIDENT_IMAGE_ID": target_id})
                if result["result"] in ("started", "current", "unavailable"):
                    break
                if result["result"] != "busy":
                    raise RuntimeError("Unexpected restart result")
                if time.monotonic() >= deadline:
                    break
                time.sleep(15)
            if result["result"] == "current":
                with self.lock:
                    atomic(self.directory / f"resident-{resident_id}.json", result)
                    proven.append(resident_id)
                    self.report("resident healthy", resident_id=resident_id)
                return
            if result["result"] != "started":
                with self.lock:
                    skipped.append(resident_id)
                    self.report("busy resident left unchanged", skipped=list(skipped))
                return
            with self.lock:
                started[resident_id] = result["command_id"]
            self.report("waiting for resident's server", resident_id=resident_id)
            # The VM fetches the image from the house before it can restart.
            deadline = time.monotonic() + self.settings.get("vm_restart_wait_seconds", 3600)
            while True:
                status = self.rails(script, {
                    "DEPLOY_VM_MODE": "status", "DEPLOY_RESIDENT_ID": str(resident_id),
                    "DEPLOY_RESIDENT_IMAGE_ID": target_id,
                    "DEPLOY_VM_COMMAND_ID": str(result["command_id"])})
                if status["result"] == "healthy":
                    with self.lock:
                        atomic(self.directory / f"resident-{resident_id}.json", status)
                        proven.append(resident_id)
                        self.report("resident healthy", resident_id=resident_id)
                    return
                if status["result"] != "pending":
                    raise RuntimeError("VM resident restart failed; turns stay held for operator review")
                if time.monotonic() >= deadline:
                    raise RuntimeError("VM resident restart did not settle; turns stay held until it does")
                time.sleep(15)

        # If no stock resident has proven this image yet (every host resident
        # was busy, or there are only VMs), one VM proves it first. A failure
        # here raises before any other VM is touched; a busy one is skipped.
        remaining = list(vm_running)
        while remaining and not proven:
            roll_one(remaining.pop(0))
        # Then each VM restarts on its own machine, so the rest go at once;
        # the first failure is raised once every other VM has settled.
        errors = []
        with ThreadPoolExecutor(max_workers=max(1, self.settings.get("vm_roll_concurrency", 32))) as pool:
            for future in [pool.submit(roll_one, r) for r in remaining]:
                try:
                    future.result()
                except Exception as error:
                    errors.append(error)
        if errors:
            raise errors[0]

    def check_runtime_permissions(self, image):
        self.run(["docker", "run", "--rm", "--network", "none", "--user", "agent",
                  "--entrypoint", "python3", image, "-c",
                  "from pathlib import Path; "
                  "root=Path('/usr/local/share/helixkit-agent'); "
                  "paths=list(root.glob('*.py'))+list(Path('/home/agent').glob('*.py')); "
                  "assert root/'runtime_settings.py' in paths; "
                  "assert root/'runtime_hooks.py' in paths; "
                  "[compile(p.read_bytes(),str(p),'exec') for p in paths]"], timeout=60)

    def acquire(self, lock):
        """The minute sweep holds this lock for one pass. A deploy that starts
        mid-pass waits for it (bounded) instead of failing and latching."""
        deadline = time.monotonic() + self.settings.get("sweep_lock_wait_seconds", 1800)
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise
                self.report("waiting for resident sweep to finish")
                time.sleep(5)

    def clean_checkouts(self):
        """Under the deployment lock: this run's clone, then other finished
        runs'. Returns nothing; what was kept is in the private log."""
        mounted = mounted_sources()
        if mounted is None:
            self.log.write("\ncheckouts kept: Docker could not list mounts\n")
            return
        if not remove_checkout(self.directory, mounted) and self.repo.exists():
            self.log.write("\ncheckout kept: a container still mounts it\n")
        pruned = prune_checkouts(mounted)
        if pruned:
            self.log.write(f"\nremoved the checkouts of {len(pruned)} finished runs\n")

    def trim_build_caches(self):
        """Under the deployment lock, after the checkouts (#1133). What each
        cache did goes to the private log only."""
        try:
            outcomes = prune_build_caches(self.settings.get("build_cache_keep_gb", BUILD_CACHE_KEEP_GB))
        except ValueError as error:
            outcomes = {"error": str(error)}
        self.log.write("\nbuild caches: " + json.dumps(outcomes, sort_keys=True) + "\n")

    def execute(self):
        try:
            # Same lock for manual runtime operations, as documented.
            with (ROOT / "deployment.lock").open("a") as lock:
                self.acquire(lock)
                if self.data["operation"] != "rails" and queue_held():
                    # Never replace a held queue (and retry its held work)
                    # without the acknowledgement the gate asks for.
                    raise RuntimeError("Held resident roll requires operator inspection")
                self.checkout()
                if self.data["state"] == "superseded":
                    return
                if self.data["operation"] in ("rails", "both"):
                    self.deploy_rails()
                if self.data["operation"] == "rails":
                    self.check_runtime_change()
                if self.data["operation"] in ("chaos", "both"):
                    self.update_chaos()
                if self.data["operation"] == "runtime":
                    self.rebuild_residents()
                if self.data["state"] != "partial":
                    self.report("verified", state="success")
        except BackupsDeferred as error:
            # Its step already says why. Not a failure: nothing switched, and
            # the gate takes the next request without an acknowledgement.
            self.log.write(f"\ndeferred: {error}\n")
            self.log.flush()
            self.report(self.data["step"], state="deferred")
        except Exception as error:
            # Detailed diagnostics stay host-only, not in status/journal/Actions.
            self.log.write(f"\n{type(error).__name__}: {error}\n")
            self.log.flush()
            self.report("failed; host operator inspection required", state="failed")
        finally:
            # This run is over whatever its state (#1057): its clone goes,
            # then any other finished run's that is still on disk, unless a
            # container still mounts it. Snapshot and deletion happen under the deployment lock, like the
            # prune CLI; if a sweep or the CLI has it, this cleanup is skipped
            # and the next one takes it (Mira, #1080).
            try:
                with (ROOT / "deployment.lock").open("a") as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        self.log.write("\ncheckouts kept: the deployment lock was held\n")
                    else:
                        self.clean_checkouts()
                        self.trim_build_caches()
            except OSError as error:
                self.log.write(f"\ncheckout cleanup incomplete: {type(error).__name__}\n")
            self.log.close()


class Sweeper(Worker):
    """The minute timer's half of a Rebuild. Each tick, every resident still
    waiting in pending-rolls.json gets one roll attempt: idle ones move, busy
    ones wait for the next minute. It never waits for a resident. A deploy that
    starts mid-tick waits for the lock (Worker.execute), so a tick never fails
    a deploy; while a deploy holds the lock the tick does nothing.

    A roll that fails, or whose outcome is unknown, is HELD: kept in the file
    and on the run's receipt, never retried automatically (retrying a broken
    image every minute is the loop the 29 Oct crash taught us to avoid). The
    others carry on. The run's receipt follows the sweep, and the first stock
    resident it proves moves the births alias if the run itself couldn't."""

    def __init__(self):
        self.settings = json.loads((CONFIG / "settings.json").read_text())
        self.log = (ROOT / "sweep.log").open("a")

    def note(self, line):
        with self.lock:
            self.log.write(line)
            self.log.flush()

    def owed_preflight(self, resident, state):
        """The checks a rebuild could not run because the resident was paused
        by its backup (#765), run here before it may be recreated. None: they
        passed and the entry no longer owes them. "busy": still paused, try
        next tick (the sweep never waits). "preflight refused": the running
        binary differs from the rebuilt one on a pinned rebuild, is newer, or
        can't be read; held for the operator like any failed roll."""
        owed = resident["preflight"]
        try:
            raw = self.resident_version({"id": resident["id"], "container_name": owed["container_name"]}, wait=0)
        except Exception as error:
            self.note(f"resident {resident['id']}: preflight {type(error).__name__}\n")
            return "preflight refused"
        if raw is None:
            return "busy"
        try:
            running, built = version_tuple(raw), version_tuple(state["chaos_version"])
        except Exception:
            return "preflight refused"
        if (owed.get("pinned") and raw != state["chaos_version"]) or built < running:
            self.note(f"resident {resident['id']}: preflight refused\n")
            return "preflight refused"
        resident.pop("preflight")
        return None

    def receipt(self, state):
        path = ROOT / "runs" / state["run"] / "status.json"
        if not path.exists():
            return
        data = json.loads(path.read_text())
        if data.get("state") not in ("partial", "failed") or data.get("acknowledged"):
            return
        waiting = [r["id"] for r in state["residents"]] + state.get("external_skipped", [])
        data["skipped"] = waiting
        data["waiting"] = [r["id"] for r in state["residents"]]
        data["held"] = state["held"]
        data["births_image_moved"] = state["births_image_moved"]
        if state.get("births_alias_failed"):
            data["births_alias_failed"] = True
        if state["held"]:
            data["step"] = "resident roll failed; held for operator review"
        elif state.get("births_alias_failed"):
            data["step"] = "births alias tag failed; held for operator review"
        elif waiting:
            data["step"] = "busy residents roll when idle"
        elif data["state"] == "partial":
            data.update(state="success", step="all residents healthy")
        atomic(path, data)

    def commit(self, state):
        """Write the pass's result, unless the queue was acknowledged meanwhile.

        acknowledge (gate.py, under gate.lock) archives a held queue; a pass
        that read it before then must not write it back. So the write happens
        under gate.lock too, and only if the file is still this run's queue.
        Lock order is always deployment.lock then gate.lock (the worker drops
        gate.lock before it takes deployment.lock; the gate never takes
        deployment.lock), so this cannot deadlock."""
        with (ROOT / "gate.lock").open("a") as gate_lock:
            fcntl.flock(gate_lock, fcntl.LOCK_EX)
            path = pending_rolls()
            if not path.exists() or json.loads(path.read_text()).get("run") != state["run"]:
                self.log.write("queue acknowledged during the pass; not written back\n")
                return False
            self.receipt(state)
            # external_skipped: VM residents still owed the image (#1029). The
            # last host resident clearing must not drop them.
            if (state["residents"] or state["held"] or state.get("births_alias_failed")
                    or state.get("external_skipped")):
                atomic(path, state)
            else:
                atomic(ROOT / "last-sweep.json", state)
                path.unlink()
            return True

    def move_births(self, state, image):
        """The first stock resident proven on the run's image moves the births
        alias, if the run couldn't. A failed tag is held, never retried."""
        if (not state.get("births_allowed", True) or state["held"] or state["births_image_moved"]
                or state.get("births_alias_failed")):
            return
        try:
            for alias in self.settings.get("stock_aliases", []):
                self.run(["docker", "tag", image, alias])
            state["births_image_moved"] = True
        except Exception as error:
            self.note(f"births alias tag failed: {type(error).__name__}\n")
            state["births_alias_failed"] = True

    def sweep_vms(self, state, proven):
        """VM residents the run skipped (busy or unreachable) get the run's
        stock image here, without waiting: a tick queues the restart, later
        ticks read whether the runner confirmed that exact image. Until one
        resident has proven the image, at most one VM is in flight. A failed or
        unsettled restart is held, like a failed host roll (turns stay held on
        the Rails side until an operator has looked)."""
        owed = state.get("external_skipped") or []
        if not owed or not state.get("stock_image") or state["held"]:
            return
        image = state["stock_image"]
        target_id = self.run(["docker", "image", "inspect", "--format", "{{.Id}}", image], capture=True)
        if not isinstance(target_id, str) or not IMAGE_ID.fullmatch(target_id):
            self.note("stock image has no image ID; VM residents left owed\n")
            return
        script = (CODE / "roll-vm-resident.rb").read_text()
        rolling = state.setdefault("vm_rolling", {})
        wait = self.settings.get("vm_restart_wait_seconds", 3600)

        def settled(resident_id, outcome):
            self.note(f"vm resident {resident_id}: {outcome}\n")
            owed.remove(resident_id)
            rolling.pop(str(resident_id), None)

        for resident_id in list(owed):
            if state["held"]:
                return
            flight = rolling.get(str(resident_id))
            if flight is None and rolling and not proven:
                # Unproven image: one VM at a time.
                continue
            if flight is None:
                # Only a VM whose confirmed image is the one that passed this
                # run's preflight is started, re-read now at admission (#1036).
                # A VM unreachable at the run, or one whose image has changed
                # since, never passed those gates: it stays owed, visibly, for
                # the next explicit run. Unreadable: left owed, not started.
                # Newer than this image: a downgrade, refused and held.
                approved = (state.get("vm_approved_images") or {}).get(str(resident_id))
                try:
                    seen = self.rails(script, {"DEPLOY_VM_MODE": "inspect",
                                               "DEPLOY_RESIDENT_ID": str(resident_id)})
                    running = seen.get("image") if seen.get("running") else None
                    if not isinstance(running, str) or not IMAGE_ID.fullmatch(running):
                        self.note(f"vm resident {resident_id}: no confirmed image; left owed\n")
                        continue
                    if running != approved:
                        self.note(f"vm resident {resident_id}: not the image this run's preflight "
                                  "passed; left owed for the next explicit run\n")
                        continue
                    newer = version_tuple(state["chaos_version"]) < version_tuple(self.image_version(running))
                except Exception as error:
                    self.note(f"\nvm resident {resident_id} version: {type(error).__name__}; left owed\n")
                    continue
                if newer:
                    self.note(f"vm resident {resident_id}: refusing runtime version downgrade\n")
                    owed.remove(resident_id)
                    state["held"].append(resident_id)
                    state["births_allowed"] = False
                    continue
                try:
                    result = self.rails(script, {
                        "DEPLOY_VM_MODE": "start", "DEPLOY_RESIDENT_ID": str(resident_id),
                        "DEPLOY_RESIDENT_IMAGE": image, "DEPLOY_RESIDENT_IMAGE_ID": target_id,
                        # Compared again under the start's own locks: the VM
                        # may change between that inspect and this start.
                        "DEPLOY_RESIDENT_EXPECTED_IMAGE_ID": approved})
                except Exception as error:
                    # Outcome unknown: a restart may have been queued. Held.
                    self.note(f"\nvm resident {resident_id}: {type(error).__name__}\n")
                    result = {"result": "unknown"}
                answer = result.get("result")
                if answer == "current":
                    settled(resident_id, "current")
                    proven = state["canary_proven"] = True
                    self.move_births(state, image)
                elif answer == "started":
                    rolling[str(resident_id)] = {"command_id": result["command_id"],
                                                 "started_at": int(time.time())}
                elif answer == "changed":
                    self.note(f"vm resident {resident_id}: image changed before the start; "
                              "left owed for the next explicit run\n")
                elif answer not in ("busy", "unavailable"):
                    owed.remove(resident_id)
                    state["held"].append(resident_id)
                    state["births_allowed"] = False
                continue
            try:
                status = self.rails(script, {
                    "DEPLOY_VM_MODE": "status", "DEPLOY_RESIDENT_ID": str(resident_id),
                    "DEPLOY_RESIDENT_IMAGE_ID": target_id,
                    "DEPLOY_VM_COMMAND_ID": str(flight["command_id"])})
            except Exception as error:
                # Reading again next tick is safe; the deadline still applies.
                self.note(f"\nvm resident {resident_id} status: {type(error).__name__}\n")
                status = {"result": "pending"}
            answer = status.get("result")
            if answer == "healthy":
                settled(resident_id, "healthy")
                proven = state["canary_proven"] = True
                self.move_births(state, image)
            elif answer != "pending" or time.time() - flight["started_at"] >= wait:
                rolling.pop(str(resident_id), None)
                owed.remove(resident_id)
                state["held"].append(resident_id)
                state["births_allowed"] = False

    def sweep(self):
        try:
            with (ROOT / "deployment.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return "deploy running"
                if not pending_rolls().exists():
                    return "nothing pending"
                state = json.loads(pending_rolls().read_text())
                state.setdefault("held", [])
                state.setdefault("births_image_moved", False)
                # A queue from before canaries existed: a stock resident it
                # proved is the same evidence.
                canary_proven = state.get("canary_proven", state["births_image_moved"])
                if state["held"] and not canary_proven:
                    # The image never ran healthy and something failed on it:
                    # roll nobody else onto it until an operator has looked.
                    return f"{len(state['residents'])} waiting, {len(state['held'])} held"
                script = (CODE / "roll-resident.rb").read_text()
                waiting = []

                def roll_one(resident):
                    if resident.get("preflight"):
                        verdict = self.owed_preflight(resident, state)
                        if verdict is not None:
                            return {"result": verdict}
                    try:
                        return self.rails(script, {
                            "DEPLOY_RESIDENT_ID": str(resident["id"]),
                            "DEPLOY_RESIDENT_IMAGE": resident["image"],
                            "DEPLOY_CHAOS_VERSION": state["chaos_version"]})
                    except Exception as error:
                        self.note(f"\nresident {resident['id']}: {type(error).__name__}\n")
                        return {"result": "unknown"}

                def record(resident, result):
                    with self.lock:
                        if result.get("result") == "busy":
                            waiting.append(resident)
                        elif result.get("result") in ("healthy", "current"):
                            self.note(f"resident {resident['id']}: {result['result']}\n")
                            if (resident.get("stock") and state.get("births_allowed", True)
                                    and not state["held"] and not state["births_image_moved"]
                                    and not state.get("births_alias_failed")):
                                try:
                                    for alias in self.settings.get("stock_aliases", []):
                                        self.run(["docker", "tag", resident["image"], alias])
                                    state["births_image_moved"] = True
                                except Exception as error:
                                    # Held like a failed roll: kept on the receipt and in
                                    # the file, never retried here. The resident itself
                                    # is healthy and is not rolled again.
                                    self.note(f"births alias tag failed: {type(error).__name__}\n")
                                    state["births_alias_failed"] = True
                        else:
                            state["held"].append(resident["id"])

                proven, untouched = roll_in_parallel(
                    state["residents"], roll_one, record,
                    concurrency=self.settings.get("roll_concurrency", 6), canary=not canary_proven)
                state["canary_proven"] = proven
                # A canary that failed here leaves the rest waiting, untouched;
                # the held entry stops the next tick from trying them.
                waiting.extend(untouched)
                waiting.sort(key=lambda r: [e["id"] for e in state["residents"]].index(r["id"]))
                state["residents"] = waiting
                self.sweep_vms(state, bool(proven or canary_proven or state["births_image_moved"]))
                state["checked_at"] = int(time.time())
                if not self.commit(state):
                    return "acknowledged during pass"
                return f"{len(waiting)} waiting, {len(state['held'])} held"
        finally:
            self.log.close()


if __name__ == "__main__":
    os.umask(0o077)
    if sys.argv[1:] == ["sweep"]:
        print(Sweeper().sweep())
        sys.exit(0)
    if sys.argv[1:] == ["prune"]:
        # Host root, by hand: the one-time sweep of the clones left before
        # #1057. Never alongside a deploy or a sweep pass.
        with (ROOT / "deployment.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit("A deploy or sweep holds the deployment lock; try again")
            print(json.dumps({"removed": len(prune_checkouts())}))
        sys.exit(0)
    if sys.argv[1:] == ["prune-caches"]:
        # Host root, by hand: the first trim of the caches left before #1133.
        # Afterwards every run does it in its cleanup. Never alongside a
        # deploy or a sweep pass.
        settings = json.loads((CONFIG / "settings.json").read_text())
        with (ROOT / "deployment.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit("A deploy or sweep holds the deployment lock; try again")
            print(json.dumps(prune_build_caches(settings.get("build_cache_keep_gb", BUILD_CACHE_KEEP_GB))))
        sys.exit(0)
    if len(sys.argv) != 2 or sys.argv[1] not in OPERATIONS:
        sys.exit(2)
    # Serialize startup with the privileged gate, which has already written
    # current.json before starting this fixed service.
    with (ROOT / "gate.lock").open("a") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        worker = Worker(sys.argv[1])
    worker.execute()
    sys.exit(0 if worker.data["state"] in ("success", "superseded", "deferred") else 1)
