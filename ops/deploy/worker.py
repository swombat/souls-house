#!/usr/bin/python3
"""Host-owned worker. Raw subprocess output never crosses the SSH boundary."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.request

from gate import ROOT, OPERATIONS, atomic

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
    match = re.fullmatch(r"chaos (\d+(?:\.\d+)+)", version)
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
            raise RuntimeError("Subprocess failed; private diagnostics retained")
        return result.stdout.strip() if capture else None

    def web(self):
        names = self.run(["docker", "ps", "--filter", "label=service=souls-house",
                          "--filter", "label=role=web", "--format", "{{.Names}}"], capture=True).splitlines()
        if len(names) != 1:
            raise RuntimeError("Expected exactly one live web container")
        return names[0]

    def rails(self, code, env=None):
        args = ["docker", "exec", "-i"]
        for key, value in (env or {}).items():
            args += ["-e", f"{key}={value}"]
        args += [self.web(), "bin/rails", "runner", "-"]
        output = self.run(args, input=code, capture=True, timeout=300)
        return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith("{")))

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
            self.run(command, timeout=7200)
        except Exception:
            # Killing a docker-run client alone doesn't stop its container.
            # Only this job's explicitly named tools container can be removed.
            self.run(["docker", "rm", "-f", name], timeout=30)
            raise

    def deploy_rails(self):
        self.report("deploying Rails")
        # Kamal deploy takes its own production deploy lock: Mac/Dell operators
        # contend for the same lock. No separate acquire (that would deadlock it).
        self.kamal("deploy", "--skip-hooks", "--version", self.data["rails_revision"])
        revision = self.data["rails_revision"]
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
        if pinned:
            # Same source must give the same binary. Check every resident before
            # touching any, so a mismatch never leaves the fleet half-rolled.
            for resident in residents:
                running = self.run(["docker", "exec", resident["container_name"], "chaos",
                                    "--version"], capture=True)
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
        pending = [{"id": r["id"], "stock": str(r["id"]) not in self.settings["custom_residents"],
                    "image": development if str(r["id"]) in self.settings["custom_residents"] else stock}
                   for r in residents]
        queue = {"run": self.data["id"], "chaos_version": version, "residents": pending,
                 "held": held, "stock_image": stock,
                 # Not ours to roll, but unresolved: the receipt never claims
                 # completion while any of these remain (VM skips, unreachable).
                 "external_skipped": list(unreachable),
                 # Set only once the alias tag has actually succeeded.
                 "births_image_moved": False, "births_allowed": True}
        atomic(pending_rolls(), queue)
        script = (CODE / "roll-resident.rb").read_text()
        # Every resident's binary is read before anyone is touched, so a
        # downgrade stops the run with the fleet unchanged.
        old_versions = {}
        for resident in residents:
            try:
                old_versions[resident["id"]] = self.run(
                    ["docker", "exec", resident["container_name"], "chaos", "--version"], capture=True)
            except Exception:
                old_versions[resident["id"]] = None
            if old_versions[resident["id"]] is not None and \
                    version_tuple(version) < version_tuple(old_versions[resident["id"]]):
                pending_rolls().unlink(missing_ok=True)
                raise RuntimeError("Refusing runtime version downgrade")

        def roll_one(entry):
            resident_id = entry["id"]
            self.report("rolling resident if idle", resident_id=resident_id)
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
            try:
                self.roll_vm_residents(vm_running, stock, version, skipped, proven)
            except Exception:
                # A VM that failed casts doubt on the image: births stay put.
                queue["births_allowed"] = False
                queue["external_skipped"] = [i for i in skipped if i not in host_waiting] + \
                    [r["id"] for r in vm_running if r["id"] not in proven and r["id"] not in skipped]
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
        if pending:
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

    def roll_vm_residents(self, vm_running, stock, version, skipped, proven):
        """Each VM gets the stock image this run built and checked, by image ID,
        through the same restart its runner does for new credentials. Turns
        are held from the moment the start is queued until the runner confirms
        that exact image. A failed restart keeps the hold and stops the run."""
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

        # Each VM restarts on its own machine, so they all go at once; the
        # first failure is raised once every other VM has settled.
        errors = []
        with ThreadPoolExecutor(max_workers=max(1, self.settings.get("vm_roll_concurrency", 32))) as pool:
            for future in [pool.submit(roll_one, r) for r in vm_running]:
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
        except Exception as error:
            # Detailed diagnostics stay host-only, not in status/journal/Actions.
            self.log.write(f"\n{type(error).__name__}: {error}\n")
            self.log.flush()
            self.report("failed; host operator inspection required", state="failed")
        finally:
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
            if state["residents"] or state["held"] or state.get("births_alias_failed"):
                atomic(path, state)
            else:
                atomic(ROOT / "last-sweep.json", state)
                path.unlink()
            return True

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
    if len(sys.argv) != 2 or sys.argv[1] not in OPERATIONS:
        sys.exit(2)
    # Serialize startup with the privileged gate, which has already written
    # current.json before starting this fixed service.
    with (ROOT / "gate.lock").open("a") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        worker = Worker(sys.argv[1])
    worker.execute()
    sys.exit(0 if worker.data["state"] in ("success", "superseded") else 1)
