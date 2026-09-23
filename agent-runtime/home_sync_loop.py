"""Periodic Git sync for an explicitly imported home; no model invocations."""
import os
from pathlib import Path
import subprocess
import time


def main():
    root = Path(os.environ['MIRA_ROOT'])
    script = root / 'shared/automation/scripts/git_sync.py'
    while True:
        try:
            subprocess.run(['python3', str(script)], cwd=root, timeout=300, check=False)
        except (OSError, subprocess.TimeoutExpired):
            # The home's BeforeTurn stale-health check exposes an interrupted run.
            print('portable home sync could not complete; inspect local sync health', flush=True)
        time.sleep(600)


if __name__ == '__main__':
    main()
