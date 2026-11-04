"""One-time operator provisioning; the Chaos database is authoritative thereafter.

Run before residents start. A partial attempt is deliberately NOT replayed: review
its private manifest and the database before repairing, so boot never silently
re-grants execution that a resident may have revoked.
"""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

MANIFEST = 'house-hooks-v1.json'
TRUST_COLUMNS = ['project_path', 'trust_level', 'created_at', 'updated_at']
HOUSE_PREFIXES = ('house-global-v1-', 'house-project-v1-')


def command(home, project, *args):
    result = subprocess.run(
        [os.environ.get('CHAOS_BIN', '/usr/local/bin/chaos'), 'hooks', *args],
        cwd=project, env={**os.environ, 'CHAOS_HOME': str(home)},
        capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError('Chaos hook provisioning failed; inspect privately before retrying')
    return result.stdout


def save(path, data):
    fd, name = tempfile.mkstemp(prefix='.house-hooks-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def prepare(home, project, run=command, global_source=None):
    home, project = Path(home).resolve(), Path(project).resolve()
    marker = home / MANIFEST
    if marker.exists():
        record = json.loads(marker.read_text())
        if record.get('version') != 1 or record.get('project') != str(project):
            raise RuntimeError('Hook migration manifest does not match this home')
        if record.get('status') == 'complete':
            return
        # A first import that failed before anything was imported or enabled
        # left nothing to replay, so it is safe to start again. Anything that
        # got further still waits for an operator (#641).
        existing = json.loads(run(home, project, 'list'))
        if record.get('status') != 'pending' or record.get('enabled') or \
                any(row['id'].startswith(HOUSE_PREFIXES) for row in existing):
            raise RuntimeError('Incomplete hook migration; operator review required (no grants replayed)')
        marker.unlink()
    sources = []
    for path, prefix, scoped in [
        (Path(global_source) if global_source else home / 'hooks.json', 'house-global-v1', False),
        (project / '.chaos/hooks.json', 'house-project-v1', True),
    ]:
        if path.exists():
            content = path.read_bytes()
            data = json.loads(content)
            # Bookkeeping keys (`_helixkit_managed`, a resident's `_note`) are
            # not part of Chaos's strict legacy schema, which rejects the whole
            # file for one of them (#641). Strip top-level `_` keys from the
            # import copy only; the source and every hook definition stay as
            # they are.
            for key in [key for key in data if key.startswith('_')]:
                del data[key]
            if data == {'hooks': {}} or (set(data) == {'hooks'} and
                    all(groups == [] for groups in data['hooks'].values())):
                continue
            imported = home / (prefix + '-import.json')
            save(imported, data)
            sources.append({'path': str(path), 'prefix': prefix, 'project': scoped,
                            'sha256': hashlib.sha256(content).hexdigest(), 'import_path': str(imported)})
    existing = json.loads(run(home, project, 'list'))
    if any(row['id'].startswith(HOUSE_PREFIXES) for row in existing):
        raise RuntimeError('Hook migration ID collision; no existing hooks changed')
    record = {'version': 1, 'project': str(project), 'status': 'pending', 'sources': sources, 'enabled': []}
    save(marker, record)
    for source in sources:
        path = Path(source['path'])
        if hashlib.sha256(path.read_bytes()).hexdigest() != source['sha256']:
            raise RuntimeError('Hook source changed during provisioning')
        args = ['--yes', 'import', source['import_path'], '--prefix', source['prefix']]
        if source['project']:
            args.append('--project')
        run(home, project, *args)
        rows = json.loads(run(home, project, 'list'))
        for row in rows:
            ident = row['id']
            if ident.startswith(source['prefix'] + '-'):
                run(home, project, '--yes', 'enable', ident)
                record['enabled'].append(ident)
                save(marker, record)
    record['status'] = 'complete'
    save(marker, record)


def ensure_house_trust(home, project):
    """Mark a house resident's own workspace trusted in this Chaos home.

    Chaos runs project hooks (the memory recall and journal reflexes) only for
    a trusted project, and skips them silently otherwise. Chaos has no
    headless trust command, so this writes the one row its trust prompt
    writes, as the README's headless method does. Births after 2026-09-30
    never got the row and ran without their hooks (#631).

    Only ever inserts: an existing row, including a resident's own
    'untrusted', is left as it is. Never called for imported homes, whose
    trust is a reviewed operator step.
    """
    home, project = Path(home).resolve(), Path(project).resolve()
    path = home / 'chaos.sqlite'
    if not path.exists():
        return 'skipped (no Chaos database yet)'
    db = sqlite3.connect(str(path), timeout=30)
    db.isolation_level = None
    try:
        db.execute('BEGIN IMMEDIATE')
        columns = [row[1] for row in db.execute('PRAGMA table_info(project_trust)')]
        if columns != TRUST_COLUMNS:
            db.execute('ROLLBACK')
            raise RuntimeError('Unexpected Chaos trust schema; workspace trust not recorded')
        row = db.execute('SELECT trust_level FROM project_trust WHERE project_path = ?',
                         (str(project),)).fetchone()
        if row is None:
            now = int(time.time())
            db.execute('INSERT INTO project_trust VALUES (?, ?, ?, ?)',
                       (str(project), 'trusted', now, now))
        db.execute('COMMIT')
        return 'granted' if row is None else row[0]
    finally:
        db.close()


def homes():
    home = Path(os.environ.get('CHAOS_HOME', str(Path.home() / '.chaos')))
    oauth = home / 'oauth-runtime'
    return [home] + ([oauth] if oauth.is_dir() else [])


def main():
    project = Path(os.environ['AGENT_REPO_PATH'])
    if sys.argv[1:] == ['--house-trust']:
        for home in homes():
            print('Workspace trust: ' + ensure_house_trust(home, project))
        return
    home = Path(os.environ.get('CHAOS_HOME', str(Path.home() / '.chaos')))
    prepare(home, project)
    oauth = home / 'oauth-runtime'
    if oauth.is_dir():
        prepare(oauth, project, global_source=home / 'hooks.json')
    print('Chaos database hooks ready')


if __name__ == '__main__':
    main()
