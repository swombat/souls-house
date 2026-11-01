"""Exercise the AST-compacted modules used by cloud-init, not only originals."""
import ast
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def strip_docstrings(tree):
    for node in ast.walk(tree):
        if isinstance(node, (ast.Name, ast.Attribute)) and "__doc__" in (getattr(node, "id", None), getattr(node, "attr", None)):
            raise ValueError("runner reads __doc__")
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
                node.body = body[1:] or [ast.Pass()]
    return tree


class PackagedRunnerTest(unittest.TestCase):
    def test_compacted_modules_pass_the_complete_runner_suite(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as staging:
            staging = Path(staging)
            target = staging / "host-runner"
            target.mkdir()
            for name in ("souls_house_runner.py", "backup_proxy.py"):
                # As RunnerUserData.compact_source: docstrings removed (#593).
                original = strip_docstrings(ast.parse((root / "host-runner" / name).read_text()))
                compact = ast.unparse(original) + "\n"
                self.assertEqual(ast.dump(original, include_attributes=False),
                                 ast.dump(ast.parse(compact), include_attributes=False))
                (target / name).write_text(compact)
            tests = staging / "test" / "host_runner"
            shutil.copytree(Path(__file__).parent, tests, ignore=shutil.ignore_patterns("__pycache__"))
            (tests / Path(__file__).name).unlink()  # Do not recursively run this packaging check.
            fixtures = staging / "test" / "fixtures" / "files"
            fixtures.mkdir(parents=True)
            shutil.copy2(root / "test" / "fixtures" / "files" / "runner_signature_vector.json", fixtures)
            home = staging / "home"
            home.mkdir()
            env = {"PATH": os.defpath, "HOME": str(home),
                   "PYTHONPATH": os.environ.get("PYTHONPATH", "")}
            if os.environ.get("RESTIC_TEST_BINARY"):
                env["RESTIC_TEST_BINARY"] = os.environ["RESTIC_TEST_BINARY"]
            result = subprocess.run([sys.executable, "-m", "unittest", "discover",
                                     "-s", str(tests), "-p", "*test.py"],
                                    cwd=staging, env=env, capture_output=True, timeout=90)
            self.assertEqual(0, result.returncode, result.stderr.decode())
