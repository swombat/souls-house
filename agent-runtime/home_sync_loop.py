"""Periodic Git sync for an explicitly imported home; no model invocations.

The sync script comes from the home's manifest (`sync`, relative to the home
root) or, for mira_v1 only, from its documented compatibility default. It is
run as an argument list to the Python interpreter, never through a shell.

Every attempt is recorded in a small JSON status file, which the trigger shim
exposes on /health and which the resident's own hooks may read. Failures are
also logged at ERROR level to the container log.
"""
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import imported_home

SYNC_INTERVAL_SECS = 600
SYNC_TIMEOUT_SECS = 300
DEFAULT_STATUS_PATH = '/home/agent/state/home-sync/status.json'
PYTHON = 'python3'  # unchanged from the original loop: PATH resolution, argv only

log = logging.getLogger('home-sync')


def status_path():
    return Path(os.environ.get('SOULSHOUSE_HOME_SYNC_STATUS', DEFAULT_STATUS_PATH))


def _now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def read_status(path=None):
    path = Path(path or status_path())
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {'state': 'unreadable'}


def write_status(status, path=None):
    path = Path(path or status_path())
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(status, sort_keys=True))
    os.replace(temporary, path)


def run_once(runner=subprocess.run, path=None):
    """Run one sync attempt and record its outcome. Returns the new status."""
    previous = read_status(path) or {}
    status = {
        'profile': os.environ.get('SOULSHOUSE_HOME_PROFILE'),
        'interval_secs': SYNC_INTERVAL_SECS,
        'last_attempt_at': _now(),
        'last_success_at': previous.get('last_success_at'),
        'consecutive_failures': previous.get('consecutive_failures', 0),
    }
    error = None
    try:
        root = imported_home.home_root()
        manifest = json.loads((root / 'resident-home.json').read_text())
        status['script'] = imported_home.sync_relative_path(manifest)
        script = imported_home.sync_script(root, manifest)
    except (ValueError, KeyError, OSError) as failure:
        error = f'sync script unavailable: {failure}'
    else:
        try:
            result = runner([PYTHON, str(script)], cwd=root, timeout=SYNC_TIMEOUT_SECS, check=False)
        except subprocess.TimeoutExpired:
            error = f'sync timed out after {SYNC_TIMEOUT_SECS}s'
        except OSError as failure:
            error = f'sync could not start: {failure}'
        else:
            if result.returncode != 0:
                error = f'sync exited with status {result.returncode}'
    if error:
        status.update(state='error', last_error=error,
                      consecutive_failures=status['consecutive_failures'] + 1)
        log.error('portable home sync failed: %s', error)
    else:
        status.update(state='ok', last_error=None, last_success_at=status['last_attempt_at'],
                      consecutive_failures=0)
    try:
        write_status(status, path)
    except OSError as failure:
        log.error('portable home sync status could not be written: %s', failure)
    return status


def health(path=None, now=None):
    """Summarise the status file for the shim's /health response."""
    status = read_status(path)
    if status is None:
        return {'state': 'unknown', 'detail': 'no sync attempt recorded yet'}
    summary = dict(status)
    last_success = status.get('last_success_at')
    if status.get('state') == 'ok' and last_success:
        try:
            age = ((now or datetime.now(timezone.utc)) - datetime.fromisoformat(last_success)).total_seconds()
        except ValueError:
            age = None
        if age is not None and age > 3 * SYNC_INTERVAL_SECS:
            # The loop itself has stopped: its last success is old and nothing
            # newer was recorded.
            summary['state'] = 'stale'
    return summary


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s [home-sync] %(levelname)s %(message)s')
    while True:
        run_once()
        time.sleep(SYNC_INTERVAL_SECS)


if __name__ == '__main__':
    main()
