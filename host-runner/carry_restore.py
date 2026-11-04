"""restore_carry (#426 slice 3C, checkpoint 2): a moving resident's Chaos and
state homes, carried from the house, restored onto this server.

The house took one restic snapshot of the stopped resident's house `chaos`
and `state` volumes into this resident's own repository (paths /carry/chaos
and /carry/state) and recorded, for each, a shape digest made by
carry_shape.sh in the stopped window. This command:

- refuses unless both target volumes are empty: it never overwrites a home
  (a retry after a lost answer is recognised by the marker it keeps in the
  runner's own state directory, never inside the volumes);
- restores that one snapshot, by id, through the house's backup proxy with
  `--no-lock` (the house serves a restore_carry command reads only), and
  `--verify`, so restic re-reads every restored file against its hashes;
- runs the same carry_shape.sh over each restored volume and compares the
  result with the house's digest and entry count;
- on any failure, removes the two volumes it proved empty, so a retry starts
  from empty again. It never touches a volume that had anything in it.

Nothing about the files leaves the server except the two digests and counts.
"""

import hmac
import os
import re
import secrets
import tempfile
import time

from backup_proxy import (CLEANUP_SECONDS, HEX_RE, MAX_DEADLINE_SECONDS, RESTIC_IMAGE, UUID_RE, BackupProxy,
                          bounded_docker)
from souls_house_runner import BadCommand, CommandFailed, NAME_RE, volume_name

CARRY_ROLES = ("chaos", "state")
CARRY_TOOL_PREFIX = "souls-house-carry-"
CARRY_TOOL_FILTER = "name=^/souls-house-carry-[0-9a-f]{24}$"
SHAPE_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "carry_shape.sh")
SHAPE_RE = re.compile(r"entries (0|[1-9][0-9]{0,9})\nshape ([0-9a-f]{64})\n?\Z")


class CarryFailed(CommandFailed):
    def __init__(self, message, result):
        super().__init__(message)
        self.result = result


def _require(condition, message):
    if not condition:
        raise BadCommand(message)


def validate_carry(payload):
    fields = {"container_name", "agent_uuid", "restic_password", "snapshot_id", "deadline_seconds", "shapes"}
    _require(isinstance(payload, dict) and set(payload) == fields, "bad restore_carry fields")
    _require(isinstance(payload["container_name"], str) and NAME_RE.fullmatch(payload["container_name"]),
             "bad container_name")
    _require(isinstance(payload["agent_uuid"], str) and UUID_RE.fullmatch(payload["agent_uuid"]), "bad agent_uuid")
    _require(isinstance(payload["snapshot_id"], str) and HEX_RE.fullmatch(payload["snapshot_id"]), "bad snapshot_id")
    password = payload["restic_password"]
    _require(isinstance(password, str) and 1 <= len(password) <= 4096 and
             not any(char in password for char in "\r\n\0"), "bad restic_password")
    deadline = payload["deadline_seconds"]
    _require(type(deadline) is int and CLEANUP_SECONDS < deadline <= MAX_DEADLINE_SECONDS, "bad carry deadline")
    shapes = payload["shapes"]
    _require(isinstance(shapes, dict) and set(shapes) == set(CARRY_ROLES), "bad shapes")
    for role in CARRY_ROLES:
        shape = shapes[role]
        _require(isinstance(shape, dict) and set(shape) == {"entries", "shape"} and
                 type(shape["entries"]) is int and shape["entries"] >= 0 and
                 isinstance(shape["shape"], str) and HEX_RE.fullmatch(shape["shape"]), f"bad {role} shape")
    return dict(payload)


def parse_shape(output):
    """Exactly the two lines carry_shape.sh prints, or a failure."""
    match = SHAPE_RE.fullmatch(output or "")
    if not match:
        raise CommandFailed("could not read the restored home's shape")
    return {"entries": int(match.group(1)), "shape": match.group(2)}


def restore_argv(name, env_file, tool, snapshot_id):
    """Writable mounts of exactly the two carried volumes; root inside the tool
    only so modes and owners come back as they were."""
    argv = [
        "docker", "run", "--rm", "--pull", "never", "--name", tool,
        "--network", "host", "--read-only", "--cap-drop", "ALL",
        "--cap-add", "CHOWN", "--cap-add", "FOWNER", "--cap-add", "DAC_OVERRIDE", "--cap-add", "DAC_READ_SEARCH",
        "--security-opt", "no-new-privileges", "--memory", "512m", "--cpus", "1",
        "--pids-limit", "64", "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=64m",
        "--env-file", env_file,
    ]
    for role in CARRY_ROLES:
        argv += ["--mount", f"type=volume,src={volume_name(name, role)},dst=/restore/{role}"]
    argv += [RESTIC_IMAGE, "--no-cache", "--no-lock", "-o", "rest.connections=1",
             "restore", f"{snapshot_id}:/carry", "--target", "/restore", "--verify"]
    return argv


def shape_argv(name, role, tool, script):
    return [
        "docker", "run", "--rm", "--pull", "never", "--name", tool,
        "--network", "none", "--read-only", "--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH",
        "--security-opt", "no-new-privileges", "--memory", "256m", "--pids-limit", "64",
        "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=256m",
        "--mount", f"type=volume,src={volume_name(name, role)},dst=/v,readonly",
        "--entrypoint", "sh", RESTIC_IMAGE, "-c", script, "carry-shape", "/v",
    ]


def run_restore_carry(payload, host, *, signed_request, docker=None, proxy_factory=BackupProxy,
                      clock=time.monotonic, script=None):
    """host supplies volume_is_empty(volume) -> bool (creating it empty when
    missing), volume_exists(volume), remove_volume(volume) -> bool, and
    read_/write_/clear_carry_marker(name), kept in the runner's own state
    directory, never inside a resident's volume."""
    spec = validate_carry(payload)
    name = spec["container_name"]
    docker = docker or bounded_docker
    if script is None:
        with open(SHAPE_SCRIPT, encoding="utf-8") as handle:
            script = handle.read()
    started = clock()
    ends = started + spec["deadline_seconds"]
    work_ends = ends - CLEANUP_SECONDS
    result = {"container_name": name, "snapshot_id": spec["snapshot_id"], "shapes": {}, "tools_stopped": False,
              "duration_ms": 0, "already": False}
    remembered = host.read_carry_marker(name)
    if remembered is not None:
        _require(remembered.get("snapshot_id") == spec["snapshot_id"] and remembered.get("shapes") == spec["shapes"],
                 "this resident's homes were claimed for a different carry")
        if remembered.get("state") == "verified":
            # A lost acknowledgement: the restored copy stands, untouched.
            result.update(shapes=remembered["shapes"], tools_stopped=True, already=True)
            return result

    def remaining():
        seconds = work_ends - clock()
        if seconds <= 0:
            raise CommandFailed("restore_carry deadline exceeded")
        return seconds

    ok, _ = docker(["docker", "container", "inspect", name], timeout=min(10, remaining()))
    _require(not ok, "the resident already exists on this server; carry restores only before its first start")
    claimed = [volume_name(name, role) for role in CARRY_ROLES]
    if remembered is not None:
        # An interrupted attempt for this same carry claimed these volumes
        # when they were empty and the resident had never started (checked
        # above, and still true): what is in them is only its partial
        # restore, so they are discarded and begun again from empty.
        for volume in claimed:
            if not host.remove_volume(volume):
                raise CommandFailed("could not clear an interrupted restore")
    for role, volume in zip(CARRY_ROLES, claimed):
        _require(host.volume_is_empty(volume), f"{role} volume is not empty; restore_carry never overwrites a home")
    # The claim is written before anything is restored, so a retry can tell
    # its own partial restore from a home it must never touch.
    host.write_carry_marker(name, {"state": "claimed", "snapshot_id": spec["snapshot_id"], "shapes": spec["shapes"]})

    tools = []
    error = None
    verified = False
    try:
        ok, _ = docker(["docker", "image", "inspect", RESTIC_IMAGE], timeout=remaining())
        if not ok:
            ok, _ = docker(["docker", "pull", RESTIC_IMAGE], timeout=remaining())
            if not ok:
                raise CommandFailed("could not fetch the restore image")
        with tempfile.TemporaryDirectory(prefix="souls-house-carry-") as temp:
            os.chmod(temp, 0o700)
            env_file = os.path.join(temp, "restic.env")
            with open(env_file, "x", encoding="utf-8") as handle:
                os.chmod(env_file, 0o600)
                handle.write(f"RESTIC_PASSWORD={spec['restic_password']}\n")
            with proxy_factory(signed_request, work_ends) as proxy:
                with open(env_file, "a", encoding="utf-8") as handle:
                    handle.write(f"RESTIC_REPOSITORY={proxy.repository}\n")
                tool = CARRY_TOOL_PREFIX + secrets.token_hex(12)
                tools.append(tool)  # remember before launch, including timeouts
                ok, _ = docker(restore_argv(name, env_file, tool, spec["snapshot_id"]), timeout=remaining())
                if not ok:
                    raise CommandFailed("restic restore failed")
        for role in CARRY_ROLES:
            tool = CARRY_TOOL_PREFIX + secrets.token_hex(12)
            tools.append(tool)
            ok, output = docker(shape_argv(name, role, tool, script), timeout=remaining())
            if not ok:
                raise CommandFailed(f"could not measure the restored {role} home")
            result["shapes"][role] = parse_shape(output)
        for role in CARRY_ROLES:
            want, got = spec["shapes"][role], result["shapes"][role]
            if got["entries"] != want["entries"] or not hmac.compare_digest(got["shape"], want["shape"]):
                raise CommandFailed(f"the restored {role} home does not match the house's")
        verified = True
    except BadCommand:
        raise
    except Exception as caught:
        # No restic output or password is included in a command answer.
        error = str(caught) if isinstance(caught, CommandFailed) else f"restore_carry failed: {type(caught).__name__}"
    finally:
        cleanup_ok = True
        if tools:
            try:
                ok, output = docker(["docker", "rm", "-f", *tools], timeout=max(0.001, min(5, ends - clock())))
                missing = output.splitlines()
                if not ok and not (missing and all(
                    re.fullmatch(r"Error response from daemon: No such container: souls-house-carry-[0-9a-f]{24}", line)
                    for line in missing
                )):
                    cleanup_ok = False
            except Exception:
                cleanup_ok = False
        try:
            ok, output = docker(["docker", "ps", "-a", "--filter", CARRY_TOOL_FILTER, "--format", "{{.Names}}"],
                                timeout=5)
            result["tools_stopped"] = cleanup_ok and ok and not output.strip()
        except Exception:
            result["tools_stopped"] = False
        if not result["tools_stopped"]:
            error = error or "cannot verify restore tools stopped"
            verified = False
        if not verified and result["tools_stopped"]:
            # Both volumes were proved empty before this command wrote to
            # them, so removing them loses nothing and lets a retry begin
            # from empty. With a tool possibly still running, leave them.
            for volume in claimed:
                if not host.remove_volume(volume):
                    error = error or "could not clear a partly restored home"
            if error and all(not host.volume_exists(volume) for volume in claimed):
                host.clear_carry_marker(name)
        result["duration_ms"] = round((clock() - started) * 1000)
    if error:
        raise CarryFailed(error, result)
    host.write_carry_marker(name, {"state": "verified", "snapshot_id": spec["snapshot_id"], "shapes": result["shapes"]})
    return result
