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


def verify_migrations(before, after):
    old, new = migration_blobs(before), migration_blobs(after)
    if any(new.get(path) != sha for path, sha in old.items()):
        raise RuntimeError("Existing runtime migrations changed; operator review required")


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
        ACTIVE resident is real damage, so that still stops the run."""
        present, absent = [], []
        for resident in residents:
            if self.container_exists(resident["container_name"]):
                present.append(resident)
            elif resident["active"]:
                raise RuntimeError("Active resident has no container; operator review required")
            else:
                absent.append(resident["id"])
        if absent:
            self.report("inactive residents without containers left alone", absent=absent)
        return present

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
            "puts({residents:Agent.hosted.where.not(container_name:[nil,''])"
            ".order(:id).map{|a| a.attributes.slice('id','container_name','container_image','active','paused')}}.to_json)"
        )["residents"]
        residents = self.present_residents(residents)
        if not residents:
            raise RuntimeError("No resident containers")
        atomic(self.directory / "previous-residents.json", residents)
        previous_refs = set()
        for resident in residents:
            profile = self.settings["custom_residents"].get(str(resident["id"]))
            repository = resident["container_image"].rsplit(":", 1)[0]
            if profile != "development" and repository not in self.settings["stock_repositories"]:
                raise RuntimeError("Unrecognised custom image; operator review required")
            info = self.inspect_image(resident["container_image"])
            before_ref = info["Config"].get("Labels", {}).get("house.souls.chaos-ref", "")
            if not SHA.fullmatch(before_ref):
                raise RuntimeError("Previous runtime has no source label")
            previous_refs.add(before_ref)
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
            verify_migrations(github(f"git/trees/{old}?recursive=1"), target_tree)

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
        development = None
        if any(str(r["id"]) in self.settings["custom_residents"] for r in residents):
            development = self.settings["development_repository"] + ":" + tag
            self.report("building development runtime layer")
            self.run(["docker", "build", "--build-arg", f"MIRA_BASE_IMAGE={stock}",
                      "-f", str(self.repo / "agent-runtime/Dockerfile.mira-dev"),
                      "-t", development, str(self.repo / "agent-runtime")], timeout=7200)
            self.check_runtime_permissions(development)
        skipped = []
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
        if skipped:
            self.report("runtime rollout incomplete", state="partial", skipped=skipped)
            return
        for alias in self.settings["stock_aliases"]:
            self.run(["docker", "tag", stock, alias])
        self.report("all residents healthy")

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
