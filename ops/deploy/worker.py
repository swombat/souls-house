#!/usr/bin/python3
"""Host-owned worker. Raw subprocess output never crosses the SSH boundary."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

from gate import ROOT, OPERATIONS, atomic

CONFIG = Path("/etc/house-deploy")
CODE = Path("/opt/house-deploy")
SHA = re.compile(r"[0-9a-f]{40}")
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")


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
        self.data.update(step=step, **values)
        atomic(self.directory / "status.json", self.data)

    def run(self, args, *, input=None, capture=False, timeout=3600, cwd=None, umask=-1):
        result = subprocess.run(args, input=input, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, cwd=cwd, umask=umask)
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
        script = (CODE / "roll-resident.rb").read_text()
        for resident in residents:
            resident_id = resident["id"]
            image = development if str(resident_id) in self.settings["custom_residents"] else stock
            old_version = self.run(["docker", "exec", resident["container_name"], "chaos",
                                    "--version"], capture=True)
            if version_tuple(version) < version_tuple(old_version):
                raise RuntimeError("Refusing runtime version downgrade")
            self.report("waiting for idle resident", resident_id=resident_id)
            deadline = time.monotonic() + self.settings.get("idle_wait_seconds", 600)
            while True:
                result = self.rails(script, {
                    "DEPLOY_RESIDENT_ID": str(resident_id),
                    "DEPLOY_RESIDENT_IMAGE": image, "DEPLOY_CHAOS_VERSION": version})
                if result["result"] in ("healthy", "current"):
                    atomic(self.directory / f"resident-{resident_id}.json", result)
                    self.report("resident healthy", resident_id=resident_id)
                    break
                if result["result"] != "busy":
                    raise RuntimeError("Unexpected restart result")
                if time.monotonic() >= deadline:
                    skipped.append(resident_id)
                    self.report("busy resident left unchanged", skipped=skipped)
                    break
                time.sleep(15)
        if vm_running:
            self.roll_vm_residents(vm_running, stock, version, skipped)
        if skipped:
            self.report("runtime rollout incomplete", state="partial", skipped=skipped)
            return
        for alias in self.settings["stock_aliases"]:
            self.run(["docker", "tag", stock, alias])
        self.report("all residents healthy")

    def vm_script(self):
        return (CODE / "roll-vm-resident.rb").read_text()

    def image_version(self, image):
        return self.run(["docker", "run", "--rm", "--network", "none", "--entrypoint",
                         "chaos", image, "--version"], capture=True)

    def roll_vm_residents(self, vm_running, stock, version, skipped):
        """Each VM gets the stock image this run built and checked, by image ID,
        through the same restart its runner does for new credentials. Turns
        are held from the moment the start is queued until the runner confirms
        that exact image. A failed restart keeps the hold and stops the run."""
        target_id = self.run(["docker", "image", "inspect", "--format", "{{.Id}}", stock],
                             capture=True)
        if not IMAGE_ID.fullmatch(target_id):
            raise RuntimeError("Built image has no image ID")
        script = self.vm_script()
        for resident in vm_running:
            resident_id = resident["id"]
            if version_tuple(version) < version_tuple(self.image_version(resident["running_image"])):
                raise RuntimeError("Refusing runtime version downgrade")
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
                atomic(self.directory / f"resident-{resident_id}.json", result)
                self.report("resident healthy", resident_id=resident_id)
                continue
            if result["result"] != "started":
                skipped.append(resident_id)
                self.report("busy resident left unchanged", skipped=skipped)
                continue
            self.report("waiting for resident's server", resident_id=resident_id)
            # The VM fetches the image from the house before it can restart.
            deadline = time.monotonic() + self.settings.get("vm_restart_wait_seconds", 3600)
            while True:
                status = self.rails(script, {
                    "DEPLOY_VM_MODE": "status", "DEPLOY_RESIDENT_ID": str(resident_id),
                    "DEPLOY_RESIDENT_IMAGE_ID": target_id,
                    "DEPLOY_VM_COMMAND_ID": str(result["command_id"])})
                if status["result"] == "healthy":
                    atomic(self.directory / f"resident-{resident_id}.json", status)
                    self.report("resident healthy", resident_id=resident_id)
                    break
                if status["result"] != "pending":
                    raise RuntimeError("VM resident restart failed; turns stay held for operator review")
                if time.monotonic() >= deadline:
                    raise RuntimeError("VM resident restart did not settle; turns stay held until it does")
                time.sleep(15)

    def check_runtime_permissions(self, image):
        self.run(["docker", "run", "--rm", "--network", "none", "--user", "agent",
                  "--entrypoint", "python3", image, "-c",
                  "from pathlib import Path; "
                  "root=Path('/usr/local/share/helixkit-agent'); "
                  "paths=list(root.glob('*.py'))+list(Path('/home/agent').glob('*.py')); "
                  "assert root/'runtime_settings.py' in paths; "
                  "assert root/'runtime_hooks.py' in paths; "
                  "[compile(p.read_bytes(),str(p),'exec') for p in paths]"], timeout=60)

    def execute(self):
        try:
            # Same lock for manual runtime operations, as documented.
            with (ROOT / "deployment.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.checkout()
                if self.data["state"] == "superseded":
                    return
                if self.data["operation"] in ("rails", "both"):
                    self.deploy_rails()
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


if __name__ == "__main__":
    os.umask(0o077)
    if len(sys.argv) != 2 or sys.argv[1] not in OPERATIONS:
        sys.exit(2)
    # Serialize startup with the privileged gate, which has already written
    # current.json before starting this fixed service.
    with (ROOT / "gate.lock").open("a") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        worker = Worker(sys.argv[1])
    worker.execute()
    sys.exit(0 if worker.data["state"] in ("success", "superseded") else 1)
