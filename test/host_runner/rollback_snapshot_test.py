"""rollback_snapshot (#426 3C rollback) with fakes: no docker, network or
restic ever runs. The fake docker records every argv, and the env file's
contents at the moment each restic run is launched."""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import rollback_snapshot as rs  # noqa: E402
from souls_house_runner import BadCommand, CommandFailed  # noqa: E402

UUID = "12345678-1234-1234-1234-123456789012"
SNAPSHOT = "e" * 64
NAME = "agent-rollback"
SHAPES = {role: {"entries": index + 1, "shape": "abcde"[index] * 64} for index, role in enumerate(rs.ROLES)}
CONTAINER = "c" * 64
STOPPED = {"Running": False, "Paused": False, "Restarting": False, "Dead": False, "Status": "exited",
           "StartedAt": "2026-11-11T10:00:00.000000001Z", "FinishedAt": "2026-11-11T12:00:00.000000001Z"}
LATER_STOP = {**STOPPED, "StartedAt": "2026-11-11T12:30:00.000000001Z", "FinishedAt": "2026-11-11T12:40:00.000000001Z"}
RUNNING = {**STOPPED, "Running": True, "Status": "running", "FinishedAt": "0001-01-01T00:00:00Z"}


def payload(**overrides):
    base = {"container_name": NAME, "agent_uuid": UUID, "restic_password": "s3cr3t-pw",
            "generation": 3, "deadline_seconds": 300}
    base.update(overrides)
    return base


class FakeProxy:
    repository = "rest:http://127.0.0.1:9/"

    def __init__(self, signed_request, ends):
        self.signed_request = signed_request

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeDocker:
    def __init__(self):
        self.calls = []
        self.envs = []
        self.states = []  # successive container states; the last one repeats
        self.volumes = {f"{NAME}-{role}" for role in rs.ROLES}
        self.shapes = dict(SHAPES)
        self.read_back = None
        self.fail = set()  # "backup", "snapshots", "check", "ps"
        self.leftover_tools = False
        self.after_backup = None
        self.container = CONTAINER
        self.tags = []

    def state(self):
        if not self.states:
            return STOPPED
        return self.states.pop(0) if len(self.states) > 1 else self.states[0]

    def __call__(self, argv, timeout=None):
        self.calls.append(list(argv))
        assert timeout is None or timeout > 0
        if argv[:2] == ["docker", "inspect"]:
            assert argv[2:4] == ["--format", "{{json .Id}} {{json .State}}"], argv
            state = self.state()
            if state is None:
                return False, "No such object"
            return True, f"{json.dumps(self.container)} {json.dumps(state)}"
        if argv[:3] == ["docker", "volume", "inspect"]:
            return argv[3] in self.volumes, ""
        if argv[:3] == ["docker", "image", "inspect"]:
            return True, ""
        if argv[:3] == ["docker", "rm", "-f"]:
            return True, ""
        if argv[:3] == ["docker", "ps", "-a"]:
            return "ps" not in self.fail, ("souls-house-rollback-" + "0" * 24 if self.leftover_tools else "")
        if argv[:2] == ["docker", "run"]:
            if "--entrypoint" in argv:
                mount = argv[argv.index("--mount") + 1]
                role = mount.split("src=")[1].split(",")[0].rsplit("-", 1)[1]
                shape = self.shapes[role]
                return True, f"entries {shape['entries']}\nshape {shape['shape']}\n"
            env_file = argv[argv.index("--env-file") + 1]
            with open(env_file, encoding="utf-8") as handle:
                self.envs.append(handle.read())
            command = argv[argv.index("rest.connections=1") + 1:]
            if command[0] == "backup":
                if "backup" in self.fail:
                    return False, "Fatal: s3cr3t-pw leaked?"
                self.tags = [command[i + 1] for i, part in enumerate(command) if part == "--tag"]
                if self.after_backup:
                    self.after_backup()
                return True, "\n".join([json.dumps({"message_type": "status"}),
                                        json.dumps({"message_type": "summary", "snapshot_id": SNAPSHOT})])
            if command[0] == "snapshots":
                if "snapshots" in self.fail:
                    return False, ""
                listed = self.read_back if self.read_back is not None else [{
                    "id": SNAPSHOT, "hostname": rs.HOSTNAME, "tags": list(reversed(self.tags)),
                    "paths": [f"/rollback/{role}" for role in reversed(rs.ROLES)]}]
                return True, json.dumps(listed)
            if command[0] == "check":
                return "check" not in self.fail, ""
        raise AssertionError(f"unexpected docker call {argv}")

    def restic_commands(self):
        return [call[call.index("rest.connections=1") + 1] for call in self.calls
                if call[:2] == ["docker", "run"] and "rest.connections=1" in call]


class FakeHost:
    def __init__(self, root, docker):
        self.state_dir = os.path.join(root, "state")
        os.makedirs(self.state_dir)
        self.backup_request = "signed"
        self.current_command_id = "a" * 32
        self.runner_id = "runner-one"
        self.docker = docker

    def _write_private(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)


class RollbackSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.docker = FakeDocker()
        self.host = FakeHost(self.temp.name, self.docker)
        self.all_calls = []

    def tearDown(self):
        # On every path: no volume is ever created, removed or written.
        for call in self.docker.calls + self.all_calls:
            self.assertNotIn(call[:3], (["docker", "volume", "create"], ["docker", "volume", "rm"]), call)
            for index, part in enumerate(call):
                if part == "--mount" and "type=volume" in call[index + 1]:
                    self.assertTrue(call[index + 1].endswith(",readonly"), call[index + 1])
        self.temp.cleanup()

    def run_it(self, body=None, **kwargs):
        return rs.run_rollback_snapshot(body or payload(), self.host, docker=self.docker, proxy_factory=FakeProxy,
                                        script="echo shape", **kwargs)

    def marker(self):
        with open(os.path.join(self.host.state_dir, "rollback", f"{NAME}.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def fresh(self):
        self.all_calls += self.docker.calls
        self.docker = FakeDocker()
        self.host.docker = self.docker

    def test_snapshots_all_five_homes_of_a_stopped_resident(self):
        result = self.run_it()
        self.assertEqual(SNAPSHOT, result["snapshot_id"])
        self.assertEqual(SHAPES, result["shapes"])
        self.assertEqual((UUID, 3, NAME, True, False), (result["agent_uuid"], result["generation"],
                         result["container_name"], result["tools_stopped"], result["already"]))
        self.assertEqual(["backup", "snapshots", "check"], self.docker.restic_commands())
        backup = next(call for call in self.docker.calls if "backup" in call)
        command = backup[backup.index("backup"):]
        self.assertEqual(["backup", "--host", "souls-house-rollback", "--tag", f"agent={UUID}", "--tag", "generation=3",
                          "--tag", "rollback=v1", "--json"] + [f"/rollback/{role}" for role in rs.ROLES], command)
        mounts = [backup[i + 1] for i, part in enumerate(backup) if part == "--mount"]
        self.assertEqual([f"type=volume,src={NAME}-{role},dst=/rollback/{role},readonly" for role in rs.ROLES], mounts)
        self.assertNotIn("init", self.docker.restic_commands())
        for call in self.docker.calls:
            self.assertFalse(any("s3cr3t-pw" in part for part in call), "password never in argv")
        for env in self.docker.envs:
            self.assertIn("RESTIC_PASSWORD=s3cr3t-pw\n", env)
            self.assertIn(f"RESTIC_REPOSITORY={FakeProxy.repository}\n", env)
        marker = self.marker()
        self.assertEqual({"state": "verified", "agent_uuid": UUID, "runner_id": "runner-one", "generation": 3,
                          "snapshot_id": SNAPSHOT, "shapes": SHAPES,
                          "interval": {"container_id": CONTAINER, "started_at": STOPPED["StartedAt"],
                                       "finished_at": STOPPED["FinishedAt"]}}, marker)

    def test_refuses_a_running_paused_restarting_or_missing_resident(self):
        cases = {
            "running": RUNNING,
            "paused": {**STOPPED, "Running": True, "Paused": True, "Status": "paused"},
            "restarting": {**STOPPED, "Restarting": True, "Status": "restarting"},
            "dead": {**STOPPED, "Dead": True, "Status": "dead"},
            "missing": None,
        }
        for label, state in cases.items():
            self.fresh()
            self.docker.states = [state]
            with self.assertRaises(BadCommand, msg=label) as caught:
                self.run_it()
            self.assertIn("not stopped", str(caught.exception))
            self.assertEqual([], self.docker.restic_commands(), label)

    def test_a_remembered_snapshot_is_returned_only_while_the_resident_is_still_stopped(self):
        self.run_it()
        self.fresh()
        again = self.run_it()
        self.assertTrue(again["already"])
        self.assertEqual((SNAPSHOT, SHAPES), (again["snapshot_id"], again["shapes"]))
        self.assertEqual([], self.docker.restic_commands())
        self.fresh()
        self.docker.states = [RUNNING]
        with self.assertRaises(BadCommand):
            self.run_it()

    def test_a_start_write_stop_at_the_same_generation_takes_a_fresh_snapshot(self):
        """Mira's P1 on 06164cdd: stopped now is not the same stopped interval."""
        self.run_it()
        self.fresh()
        self.docker.states = [LATER_STOP]
        self.docker.shapes["identity"] = {"entries": 999, "shape": "f" * 64}
        result = self.run_it()
        self.assertFalse(result["already"])
        self.assertEqual({"entries": 999, "shape": "f" * 64}, result["shapes"]["identity"])
        self.assertEqual(["backup", "snapshots", "check"], self.docker.restic_commands())
        self.assertEqual(LATER_STOP["FinishedAt"], self.marker()["interval"]["finished_at"])
        self.fresh()
        self.docker.container = "d" * 64  # recreated container, same name
        self.assertFalse(self.run_it()["already"])

    def test_a_marker_for_another_generation_or_runner_is_never_reused(self):
        self.run_it()
        self.fresh()
        result = self.run_it(payload(generation=4))
        self.assertFalse(result["already"])
        self.assertEqual(["backup", "snapshots", "check"], self.docker.restic_commands())
        self.assertEqual(4, self.marker()["generation"])
        self.fresh()
        self.host.runner_id = "runner-two"
        result = self.run_it(payload(generation=4))
        self.assertFalse(result["already"])
        self.assertEqual("runner-two", self.marker()["runner_id"])

    def test_a_marker_for_another_resident_on_this_container_refuses(self):
        self.run_it()
        self.fresh()
        with self.assertRaises(BadCommand):
            self.run_it(payload(agent_uuid="87654321-4321-4321-4321-210987654321"))

    def test_validates_every_field_and_the_runner_identity(self):
        bad = [payload(extra=1), {k: v for k, v in payload().items() if k != "generation"},
               payload(generation=0), payload(generation=True), payload(generation="3"), payload(agent_uuid="x"),
               payload(container_name="../x"), payload(restic_password="a\nb"), payload(deadline_seconds=5),
               payload(deadline_seconds=10_000)]
        for body in bad:
            with self.assertRaises(BadCommand, msg=body):
                self.run_it(body)
        self.host.runner_id = None
        with self.assertRaises(BadCommand):
            self.run_it()
        self.assertEqual([], self.docker.calls)

    def test_a_missing_home_fails_before_anything_runs(self):
        self.docker.volumes.discard(f"{NAME}-state")
        with self.assertRaises(CommandFailed) as caught:
            self.run_it()
        self.assertIn("state", str(caught.exception))
        self.assertEqual([], self.docker.restic_commands())

    def test_a_snapshot_that_reads_back_differently_fails(self):
        good = {"id": SNAPSHOT, "hostname": rs.HOSTNAME, "tags": ["rollback=v1", f"agent={UUID}", "generation=3"],
                "paths": [f"/rollback/{role}" for role in rs.ROLES]}
        cases = {
            "another id": [{**good, "id": "f" * 64}],
            "another host": [{**good, "hostname": "vm"}],
            "another generation": [{**good, "tags": ["rollback=v1", f"agent={UUID}", "generation=2"]}],
            "an extra tag": [{**good, "tags": good["tags"] + ["x"]}],
            "a missing path": [{**good, "paths": good["paths"][:4]}],
            "two snapshots": [good, good],
        }
        for label, listed in cases.items():
            self.fresh()
            self.docker.read_back = listed
            with self.assertRaises(rs.RollbackSnapshotFailed, msg=label) as caught:
                self.run_it(payload(generation=3))
            self.assertIsNone(caught.exception.result["snapshot_id"], label)
            self.assertNotIn("check", self.docker.restic_commands(), label)

    def test_restic_failures_fail_without_leaking_output(self):
        for step in ("backup", "snapshots", "check"):
            self.fresh()
            self.docker.fail = {step}
            with self.assertRaises(rs.RollbackSnapshotFailed, msg=step) as caught:
                self.run_it()
            self.assertNotIn("s3cr3t", str(caught.exception))
            self.assertNotEqual("verified", self.marker()["state"], step)

    def test_a_resident_that_started_during_the_snapshot_fails(self):
        def start():
            self.docker.states = [RUNNING]
        self.docker.after_backup = start
        with self.assertRaises(rs.RollbackSnapshotFailed) as caught:
            self.run_it()
        self.assertIn("started during", str(caught.exception))
        self.assertEqual("claimed", self.marker()["state"])

    def test_a_start_and_stop_during_the_snapshot_fails(self):
        def bounce():
            self.docker.states = [LATER_STOP]
        self.docker.after_backup = bounce
        with self.assertRaises(rs.RollbackSnapshotFailed) as caught:
            self.run_it()
        self.assertIn("started during", str(caught.exception))

    def test_tools_that_cannot_be_proved_stopped_fail(self):
        self.docker.leftover_tools = True
        with self.assertRaises(rs.RollbackSnapshotFailed) as caught:
            self.run_it()
        self.assertFalse(caught.exception.result["tools_stopped"])

    def test_work_past_the_deadline_is_not_a_result(self):
        ticks = iter([0] * 12 + [400] * 200)
        with self.assertRaises(CommandFailed) as caught:
            self.run_it(clock=lambda: next(ticks))
        self.assertIn("deadline", str(caught.exception))


class DispatcherReplayTest(unittest.TestCase):
    """Mira's P2 on 06164cdd: the runner's own lost-answer replay
    (execute_command's remembered result) must not hand back a rollback
    snapshot that is no longer true. Real dispatcher, real CommandState, real
    ResidentHost; only docker and the proxy are fakes."""

    def setUp(self):
        import souls_house_runner as runner
        from unittest import mock
        self.runner = runner
        self.temp = tempfile.TemporaryDirectory()
        self.docker = FakeDocker()
        self.host = runner.ResidentHost(self.temp.name, docker=self.docker, backup_request="signed")
        self.host.runner_id = "runner-one"
        self.state = runner.CommandState(self.temp.name)
        self.patches = [mock.patch.object(rs, "bounded_docker", lambda *a, **k: self.docker(*a, **k)),
                        mock.patch.object(rs, "BackupProxy", FakeProxy),
                        mock.patch.object(rs, "SHAPE_SCRIPT", os.path.join(self.temp.name, "shape.sh"))]
        with open(os.path.join(self.temp.name, "shape.sh"), "w") as handle:
            handle.write("echo shape")
        for patch in self.patches:
            patch.start()
        self.command = {"id": "b" * 32, "kind": "rollback_snapshot", "generation": 1, "payload": payload()}

    def tearDown(self):
        for patch in self.patches:
            patch.stop()
        self.temp.cleanup()

    def execute(self, command=None):
        return self.runner.execute_command(command or self.command, self.state, self.host)[1]

    def test_a_replay_is_the_remembered_answer_only_while_it_is_still_true(self):
        first = self.execute()
        self.assertEqual("done", first["outcome"], first)
        self.assertEqual(SNAPSHOT, first["result"]["snapshot_id"])
        restic = len(self.docker.restic_commands())

        self.assertEqual(first, self.execute(), "unchanged stopped interval: same snapshot")
        self.docker.states = [RUNNING]
        replay = self.execute()
        self.assertEqual("failed", replay["outcome"])
        self.assertIn("has run since", replay["error"])
        self.docker.states = [LATER_STOP]
        self.assertEqual("failed", self.execute()["outcome"], "a start and stop since the snapshot")
        self.docker.states = [STOPPED]
        self.docker.container = "d" * 64
        self.assertEqual("failed", self.execute()["outcome"], "a recreated container")
        self.assertEqual(restic, len(self.docker.restic_commands()), "a replay never runs restic")

    def test_a_replay_of_another_generation_or_a_superseded_marker_fails(self):
        self.assertEqual("done", self.execute()["outcome"])
        newer = {**self.command, "id": "c" * 32, "payload": payload(generation=4)}
        self.assertEqual("done", self.execute(newer)["outcome"])
        replay = self.execute()
        self.assertEqual("failed", replay["outcome"], "the marker now names generation 4")
        self.state.data["highest_generation"] = 2
        self.assertEqual("refused", self.execute()["outcome"], "a stale placement generation")


if __name__ == "__main__":
    unittest.main()
