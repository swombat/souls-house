"""rollback_snapshot (#426 slice 3C, rollback): the server's final snapshot of
a resident about to be rolled back from this VM to the house.

The house has reserved a rollback generation and stopped the resident here.
This command:

- refuses unless the resident's container exists and is stopped (not running,
  not paused), and checks that again after the snapshot;
- never creates, removes or writes any of the resident's volumes: all five
  are mounted read-only, for measuring and for restic;
- measures each of the five homes with carry_shape.sh, the script the house
  measures its restored copies with;
- takes one restic snapshot of all five, through the house's backup proxy
  (the house admits writes, but never init, for a delivered rollback_snapshot),
  at paths /rollback/<role>, host souls-house-rollback, tags
  agent=<uuid> generation=<n> rollback=v1;
- reads that snapshot back (id, host, tags, paths), then runs restic check.

A marker in the runner's own state directory, bound to this runner, the
resident and the generation, lets a retry after a lost answer return the same
snapshot; even then the resident must still be stopped. Nothing about the files
leaves the server except the snapshot id and the five digests and counts.
"""

import json
import os
import re
import secrets
import tempfile
import time

from backup_proxy import (CLEANUP_SECONDS, HEX_RE, MAX_DEADLINE_SECONDS, RESTIC_IMAGE, UUID_RE, BackupProxy,
                          bounded_docker)
from carry_restore import SHAPE_SCRIPT, parse_shape
from souls_house_runner import COMMAND_ID_RE, BadCommand, CommandFailed, NAME_RE, volume_name

ROLES = ("identity", "chaos", "repo", "work", "state")
HOSTNAME = "souls-house-rollback"
TOOL_PREFIX = "souls-house-rollback-"
TOOL_FILTER = "name=^/souls-house-rollback-[0-9a-f]{24}$"
RUNNER_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
NOT_STOPPED = "resident is not stopped; rollback_snapshot needs it stopped"


class RollbackSnapshotFailed(CommandFailed):
    def __init__(self, message, result):
        super().__init__(message)
        self.result = result


def _require(condition, message):
    if not condition:
        raise BadCommand(message)


def tags(agent_uuid, generation):
    return [f"agent={agent_uuid}", f"generation={generation}", "rollback=v1"]


def paths():
    return [f"/rollback/{role}" for role in ROLES]


def validate(payload):
    fields = {"container_name", "agent_uuid", "restic_password", "generation", "deadline_seconds"}
    _require(isinstance(payload, dict) and set(payload) == fields, "bad rollback_snapshot fields")
    _require(isinstance(payload["container_name"], str) and NAME_RE.fullmatch(payload["container_name"]),
             "bad container_name")
    _require(isinstance(payload["agent_uuid"], str) and UUID_RE.fullmatch(payload["agent_uuid"]), "bad agent_uuid")
    password = payload["restic_password"]
    _require(isinstance(password, str) and 1 <= len(password) <= 4096 and
             not any(char in password for char in "\r\n\0"), "bad restic_password")
    _require(type(payload["generation"]) is int and payload["generation"] >= 1, "bad generation")
    deadline = payload["deadline_seconds"]
    _require(type(deadline) is int and CLEANUP_SECONDS < deadline <= MAX_DEADLINE_SECONDS, "bad rollback deadline")
    return dict(payload)


def _marker_path(host, name):
    return os.path.join(host.state_dir, "rollback", f"{name}.json")


def read_marker(host, name):
    path = _marker_path(host, name)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        raise CommandFailed("unreadable rollback marker") from None
    if not isinstance(data, dict):
        raise CommandFailed("unreadable rollback marker")
    return data


def write_marker(host, name, data):
    host._write_private(_marker_path(host, name), json.dumps(data, sort_keys=True))


def stopped_interval(docker, name, timeout):
    """The stopped interval the container is in, or None when it is not
    stopped: missing, running, paused, restarting or dead. The interval is the
    container's id and the StartedAt/FinishedAt of its last run; any start
    after it, even one followed by another stop, gives a different interval."""
    ok, output = docker(["docker", "inspect", "--format", "{{json .Id}} {{json .State}}", name], timeout=timeout)
    if not ok:
        return None
    try:
        container_id, state = output.strip().split(" ", 1)
        container_id, state = json.loads(container_id), json.loads(state)
    except ValueError:
        return None
    if not (isinstance(container_id, str) and re.fullmatch(r"[0-9a-f]{64}", container_id) and isinstance(state, dict)):
        return None
    if not (state.get("Running") is False and state.get("Paused") is False and not state.get("Restarting") and
            not state.get("Dead") and state.get("Status") in ("exited", "created")):
        return None
    started, finished = state.get("StartedAt"), state.get("FinishedAt")
    if not (isinstance(started, str) and started and isinstance(finished, str) and finished):
        return None
    return {"container_id": container_id, "started_at": started, "finished_at": finished}


def shape_argv(name, role, tool, script):
    return [
        "docker", "run", "--rm", "--pull", "never", "--name", tool,
        "--network", "none", "--read-only", "--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH",
        "--security-opt", "no-new-privileges", "--memory", "256m", "--pids-limit", "64",
        "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=256m",
        "--mount", f"type=volume,src={volume_name(name, role)},dst=/v,readonly",
        "--entrypoint", "sh", RESTIC_IMAGE, "-c", script, "carry-shape", "/v",
    ]


def restic_argv(name, env_file, tool, command):
    """Every home mounted read-only; DAC_READ_SEARCH so restic can read files
    of any owner, and nothing that could write them."""
    argv = [
        "docker", "run", "--rm", "--pull", "never", "--name", tool,
        "--network", "host", "--read-only", "--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH",
        "--security-opt", "no-new-privileges", "--memory", "512m", "--cpus", "1",
        "--pids-limit", "64", "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=64m",
        "--env-file", env_file,
    ]
    for role in ROLES:
        argv += ["--mount", f"type=volume,src={volume_name(name, role)},dst=/rollback/{role},readonly"]
    argv += [RESTIC_IMAGE, "--no-cache", "-o", "rest.connections=1", *command]
    return argv


def backup_command(spec):
    command = ["backup", "--host", HOSTNAME]
    for tag in tags(spec["agent_uuid"], spec["generation"]):
        command += ["--tag", tag]
    return command + ["--json", *paths()]


def parse_summary(output):
    summaries = []
    for line in (output or "").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("message_type") == "summary":
            summaries.append(entry)
    if len(summaries) != 1:
        raise CommandFailed("missing restic backup summary")
    snapshot_id = summaries[0].get("snapshot_id")
    if not isinstance(snapshot_id, str) or not HEX_RE.fullmatch(snapshot_id):
        raise CommandFailed("invalid restic backup summary")
    return snapshot_id


def check_read_back(output, snapshot_id, spec):
    """restic snapshots --json <id>: exactly that snapshot, with the host,
    the three tags and the five paths the house will restore from."""
    try:
        listed = json.loads(output or "")
    except ValueError:
        raise CommandFailed("could not read the snapshot back") from None
    if not (isinstance(listed, list) and len(listed) == 1 and isinstance(listed[0], dict)):
        raise CommandFailed("the snapshot did not read back as one snapshot")
    snapshot = listed[0]
    if snapshot.get("id") != snapshot_id:
        raise CommandFailed("the snapshot read back with another id")
    if snapshot.get("hostname") != HOSTNAME:
        raise CommandFailed("the snapshot read back with another host")
    got_tags = snapshot.get("tags")
    if not (isinstance(got_tags, list) and sorted(got_tags) == sorted(tags(spec["agent_uuid"], spec["generation"]))):
        raise CommandFailed("the snapshot read back with other tags")
    got_paths = snapshot.get("paths")
    if not (isinstance(got_paths, list) and sorted(got_paths) == sorted(paths())):
        raise CommandFailed("the snapshot read back with other paths")


def _valid_remembered(remembered):
    shapes = remembered.get("shapes")
    return (isinstance(remembered.get("snapshot_id"), str) and HEX_RE.fullmatch(remembered["snapshot_id"]) and
            isinstance(shapes, dict) and set(shapes) == set(ROLES) and
            all(isinstance(shape, dict) and set(shape) == {"entries", "shape"} and type(shape["entries"]) is int and
                shape["entries"] >= 0 and isinstance(shape["shape"], str) and HEX_RE.fullmatch(shape["shape"])
                for shape in shapes.values()))


def run_rollback_snapshot(payload, host, *, signed_request=None, docker=None, proxy_factory=None,
                          clock=time.monotonic, script=None):
    """host is the runner's ResidentHost: its backup_request transport, the
    current command id, runner_id, state_dir (the marker lives there) and docker."""
    signed_request = signed_request or host.backup_request
    if signed_request is None:
        raise BadCommand("backup transport unavailable")
    _require(isinstance(host.current_command_id, str) and COMMAND_ID_RE.fullmatch(host.current_command_id),
             "rollback command id is missing")
    runner_id = getattr(host, "runner_id", None)
    _require(isinstance(runner_id, str) and RUNNER_ID_RE.fullmatch(runner_id), "this runner does not know its own id")
    spec = validate(payload)
    name = spec["container_name"]
    docker = docker or bounded_docker
    proxy_factory = proxy_factory or BackupProxy
    if script is None:
        with open(SHAPE_SCRIPT, encoding="utf-8") as handle:
            script = handle.read()
    started = clock()
    ends = started + spec["deadline_seconds"]
    work_ends = ends - CLEANUP_SECONDS
    binding = {"agent_uuid": spec["agent_uuid"], "runner_id": runner_id, "generation": spec["generation"]}
    result = {"container_name": name, "agent_uuid": spec["agent_uuid"], "generation": spec["generation"],
              "snapshot_id": None, "shapes": {}, "tools_stopped": False, "already": False, "duration_ms": 0}

    def remaining():
        seconds = work_ends - clock()
        if seconds <= 0:
            raise CommandFailed("rollback_snapshot deadline exceeded")
        return seconds

    remembered = read_marker(host, name)
    if remembered is not None:
        _require(remembered.get("agent_uuid") == spec["agent_uuid"],
                 "this container's rollback marker belongs to another resident")
        if not all(remembered.get(key) == value for key, value in binding.items()):
            remembered = None  # another generation or runner: stale, never reused
    # Even a remembered snapshot is only handed back while the resident is
    # still in the same stopped interval it was taken in: stopped now is not
    # enough, since a start, a write and a stop would leave it stale.
    interval = stopped_interval(docker, name, min(10, remaining()))
    _require(interval is not None, NOT_STOPPED)
    if (remembered is not None and remembered.get("state") == "verified" and _valid_remembered(remembered) and
            remembered.get("interval") == interval):
        result.update(snapshot_id=remembered["snapshot_id"], shapes=remembered["shapes"], tools_stopped=True,
                      already=True, duration_ms=round((clock() - started) * 1000))
        return result

    for role in ROLES:
        ok, _ = docker(["docker", "volume", "inspect", volume_name(name, role)], timeout=min(10, remaining()))
        if not ok:
            raise CommandFailed(f"missing resident volume {role}")
    write_marker(host, name, {"state": "claimed", **binding, "interval": interval})

    tools = []
    error = None
    try:
        ok, _ = docker(["docker", "image", "inspect", RESTIC_IMAGE], timeout=remaining())
        if not ok:
            ok, _ = docker(["docker", "pull", RESTIC_IMAGE], timeout=remaining())
            if not ok:
                raise CommandFailed("could not fetch the snapshot image")
        for role in ROLES:
            tool = TOOL_PREFIX + secrets.token_hex(12)
            tools.append(tool)  # remember before launch, including timeouts
            ok, output = docker(shape_argv(name, role, tool, script), timeout=remaining())
            if not ok:
                raise CommandFailed(f"could not measure the {role} home")
            result["shapes"][role] = parse_shape(output)
        with tempfile.TemporaryDirectory(prefix="souls-house-rollback-") as temp:
            os.chmod(temp, 0o700)
            env_file = os.path.join(temp, "restic.env")
            with open(env_file, "x", encoding="utf-8") as handle:
                os.chmod(env_file, 0o600)
                handle.write(f"RESTIC_PASSWORD={spec['restic_password']}\n")
            with proxy_factory(signed_request, work_ends) as proxy:
                with open(env_file, "a", encoding="utf-8") as handle:
                    handle.write(f"RESTIC_REPOSITORY={proxy.repository}\n")

                def restic(command):
                    tool = TOOL_PREFIX + secrets.token_hex(12)
                    tools.append(tool)
                    return docker(restic_argv(name, env_file, tool, command), timeout=remaining())

                ok, output = restic(backup_command(spec))
                if not ok:
                    raise CommandFailed("restic backup failed")
                snapshot_id = parse_summary(output)
                ok, output = restic(["snapshots", "--json", snapshot_id])
                if not ok:
                    raise CommandFailed("could not read the snapshot back")
                check_read_back(output, snapshot_id, spec)
                ok, _ = restic(["check"])
                if not ok:
                    raise CommandFailed("restic check failed")
        if stopped_interval(docker, name, min(10, remaining())) != interval:
            raise CommandFailed("resident started during the rollback snapshot")
        result["snapshot_id"] = snapshot_id
    except BadCommand:
        raise
    except Exception as caught:
        # No restic output or password is included in a command answer.
        error = str(caught) if isinstance(caught, CommandFailed) else f"rollback_snapshot failed: {type(caught).__name__}"
    finally:
        cleanup_ok = True
        if tools:
            try:
                ok, output = docker(["docker", "rm", "-f", *tools], timeout=max(0.001, min(5, ends - clock())))
                missing = output.splitlines()
                if not ok and not (missing and all(
                    re.fullmatch(r"Error response from daemon: No such container: souls-house-rollback-[0-9a-f]{24}", line)
                    for line in missing
                )):
                    cleanup_ok = False
            except Exception:
                cleanup_ok = False
        try:
            ok, output = docker(["docker", "ps", "-a", "--filter", TOOL_FILTER, "--format", "{{.Names}}"],
                                timeout=max(0.001, min(5, ends - clock())))
            result["tools_stopped"] = cleanup_ok and ok and not output.strip()
        except Exception:
            result["tools_stopped"] = False
        if not result["tools_stopped"]:
            error = error or "cannot verify snapshot tools stopped"
        result["duration_ms"] = round((clock() - started) * 1000)
    if not error and clock() >= ends:
        error = "rollback_snapshot finished after its deadline"
    if error:
        result["snapshot_id"] = None
        raise RollbackSnapshotFailed(error, result)
    write_marker(host, name, {"state": "verified", **binding, "interval": interval,
                              "snapshot_id": result["snapshot_id"], "shapes": result["shapes"]})
    return result


def revalidate_replay(payload, remembered, host, *, docker=None):
    """The dispatcher remembers every answer by command id and replays it when
    the house asks again after a lost answer. For a done rollback_snapshot that
    replay must still be true: the same resident, runner and generation, the
    marker still naming that snapshot, and the resident still in the stopped
    interval it was taken in. Returns the remembered answer or a failure."""
    docker = docker or bounded_docker
    try:
        spec = validate(payload)
        result = remembered.get("result")
        name = spec["container_name"]
        marker = read_marker(host, name)
        runner_id = getattr(host, "runner_id", None)
        same = (isinstance(result, dict) and isinstance(marker, dict) and marker.get("state") == "verified" and
                marker.get("agent_uuid") == spec["agent_uuid"] and marker.get("generation") == spec["generation"] and
                marker.get("runner_id") == runner_id and marker.get("snapshot_id") == result.get("snapshot_id") and
                marker.get("shapes") == result.get("shapes"))
        if not same:
            return {"outcome": "failed", "error": "this rollback snapshot is no longer the one remembered"}
        if stopped_interval(docker, name, 10) != marker.get("interval"):
            return {"outcome": "failed", "error": "the resident has run since this rollback snapshot"}
        return remembered
    except (BadCommand, CommandFailed) as error:
        return {"outcome": "failed", "error": str(error)}
