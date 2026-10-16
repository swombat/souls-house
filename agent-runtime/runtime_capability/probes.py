"""Bounded, read-only discovery prototype; no runtime hook or installation."""

from dataclasses import dataclass
import shutil
import subprocess
import sys

from manifest import Declaration

PROBE_SECONDS = 1
# Literal scripts only: never interpolate a manifest value into Python or shell.
MODULE_PROBES = {
    "numpy": "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('numpy') is not None else 3)",
    "scipy": "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('scipy') is not None else 3)",
}


@dataclass(frozen=True)
class Result:
    channel: str
    name: str
    state: str


def probe(declaration: Declaration) -> Result:
    """Discover executables/modules, not whether analysis functions work.

    Python uses this process's interpreter and inherited environment. A child
    process bounds elapsed time and suppresses output; it is NOT an OS sandbox.
    Top-level find_spec avoids importing NumPy/SciPy and executing their code.
    """
    key = (declaration.channel, declaration.name)
    state = "unsupported"
    try:
        if key == ("apt", "ffmpeg"):
            state = "found" if shutil.which("ffmpeg") else "missing"
        elif key in {("pip", "numpy"), ("pip", "scipy")}:
            completed = subprocess.run(
                [sys.executable, "-c", MODULE_PROBES[declaration.name]],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=PROBE_SECONDS,
                check=False,
                shell=False,
            )
            state = {0: "found", 3: "missing"}.get(
                completed.returncode, "error"
            )
    except (OSError, subprocess.TimeoutExpired):
        state = "error"
    return Result(declaration.channel, declaration.name, state)
