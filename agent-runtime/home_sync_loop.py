"""Periodic Git sync for an explicitly imported home; no model invocations.

The sync script comes from the home's manifest (`sync`, relative to the home
root) or, for mira_v1 only, from its documented compatibility default. It is
run as an argument list to the Python interpreter, never through a shell.

Every attempt is recorded in a small JSON status file, which the trigger shim
exposes on /health and which the resident's own hooks may read. Failures are
also logged at ERROR level to the container log.

Invoking the script is not the same as a confirmed sync. A script can exit 0
because another sync held its lock and it did nothing. Only a confirmed
success advances `last_success_at` and clears `consecutive_failures`; a skip,
or a clean exit that cannot be confirmed, leaves both exactly as they were.

Confirmation, in order of preference:

1. The resident's own status file, when the manifest declares `sync_status`
   (relative to the home root). It counts only if this run wrote it: its
   `checked_at` must not be earlier than the start of this invocation. Its
   `status` is read as `ok` (confirmed success, and the script must also
   have exited 0), `busy` (skipped; exit 0 or 75), or `failed`/`refused`
   (failure). Anything else, or a status that contradicts the exit code, is
   a failure.
2. The exit code, when there is no fresh status file: 75 (EX_TEMPFAIL, lock
   held) is a skip; any other non-zero exit is a failure; 0 is recorded as
   `unconfirmed`, because the exit code alone cannot tell a sync from a skip.
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
EXIT_BUSY = 75  # sysexits EX_TEMPFAIL: another sync holds the lock, nothing done
RESIDENT_OUTCOMES = {'ok': 'ok', 'busy': 'skipped', 'failed': 'error', 'refused': 'error'}
DEFAULT_STATUS_PATH = '/home/agent/state/home-sync/status.json'
PYTHON = 'python3'  # unchanged from the original loop: PATH resolution, argv only

log = logging.getLogger('home-sync')


def status_path():
    return Path(os.environ.get('SOULSHOUSE_HOME_SYNC_STATUS', DEFAULT_STATUS_PATH))


def _now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def _parse_time(value):
    try:
        moment = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    except (TypeError, ValueError):
        return None
    if moment.tzinfo is None:
        return None  # a naive time cannot be compared with this run's start
    return moment.astimezone(timezone.utc)


def read_resident_status(path, started):
    """Return the resident's status only if this invocation wrote it."""
    if path is None:
        return None
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    checked = _parse_time(data.get('checked_at'))
    if checked is None or checked < started:
        return None
    return data


def classify(returncode, resident):
    """Return (outcome, error, confirmed_success_at) for one finished invocation."""
    if resident is not None:
        reported = resident.get('status')
        outcome = RESIDENT_OUTCOMES.get(reported)
        if outcome == 'ok' and returncode == 0:
            confirmed = _parse_time(resident.get('last_success_at')) or _parse_time(resident.get('checked_at'))
            return 'ok', None, confirmed.isoformat()
        if outcome == 'skipped' and returncode in (0, EXIT_BUSY):
            return 'skipped', None, None
        if outcome == 'error':
            reason = resident.get('reason') or 'no reason given'
            return 'error', f'sync reported {reported} (exit {returncode}): {reason}', None
        if outcome is None:
            return 'error', f'sync status {reported!r} is not recognised (exit {returncode})', None
        return 'error', f'sync status {reported!r} contradicts exit status {returncode}', None
    if returncode == 0:
        return 'unconfirmed', None, None
    if returncode == EXIT_BUSY:
        return 'skipped', None, None
    return 'error', f'sync exited with status {returncode}', None


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
    started = _now()
    status = {
        'profile': os.environ.get('SOULSHOUSE_HOME_PROFILE'),
        'interval_secs': SYNC_INTERVAL_SECS,
        'last_attempt_at': started.isoformat(),
        'last_success_at': previous.get('last_success_at'),
        'consecutive_failures': previous.get('consecutive_failures', 0),
        'last_error': previous.get('last_error'),
    }
    error = None
    outcome = 'error'
    success_at = None
    try:
        root = imported_home.home_root()
        manifest = json.loads((root / 'resident-home.json').read_text())
        status['script'] = imported_home.sync_relative_path(manifest)
        script = imported_home.sync_script(root, manifest)
        resident_path = imported_home.sync_status_path(root, manifest)
    except (ValueError, KeyError, OSError) as failure:
        error = f'sync script unavailable: {failure}'
    else:
        status['confirmed_by'] = 'status_file' if resident_path else 'exit_code'
        try:
            result = runner([PYTHON, str(script)], cwd=root, timeout=SYNC_TIMEOUT_SECS, check=False)
        except subprocess.TimeoutExpired:
            error = f'sync timed out after {SYNC_TIMEOUT_SECS}s'
        except OSError as failure:
            error = f'sync could not start: {failure}'
        else:
            status['last_exit_code'] = result.returncode
            resident = read_resident_status(resident_path, started)
            if resident_path and resident is None:
                status['confirmed_by'] = 'exit_code'
                status['note'] = 'resident status file was not written by this run'
            outcome, error, success_at = classify(result.returncode, resident)
    status['last_outcome'] = outcome if not error else 'error'
    if error:
        status.update(state='error', last_error=error,
                      consecutive_failures=status['consecutive_failures'] + 1)
        log.error('portable home sync failed: %s', error)
    elif outcome == 'ok':
        status.update(state='ok', last_error=None, consecutive_failures=0,
                      last_success_at=success_at or status['last_attempt_at'])
    else:
        # A skip or an unconfirmed clean exit says nothing new about whether the
        # home is in sync: keep the last confirmed state, success time and
        # failure count exactly as they were.
        status['state'] = previous.get('state') if previous.get('state') in ('ok', 'error') else outcome
        status['last_skip_at' if outcome == 'skipped' else 'last_unconfirmed_at'] = status['last_attempt_at']
        log.info('portable home sync %s; last confirmed success %s', outcome, status['last_success_at'])
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
        except (TypeError, ValueError):
            age = None
        if age is not None and age > 3 * SYNC_INTERVAL_SECS:
            # No confirmed success for three intervals: the loop has stopped,
            # or every run since has been a skip or unconfirmed.
            summary['state'] = 'stale'
    return summary


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s [home-sync] %(levelname)s %(message)s')
    while True:
        run_once()
        time.sleep(SYNC_INTERVAL_SECS)


if __name__ == '__main__':
    main()
