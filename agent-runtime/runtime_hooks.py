"""One-time operator provisioning; the Chaos database is authoritative thereafter.

Run before residents start. A partial attempt is deliberately NOT replayed: review
its private manifest and the database before repairing, so boot never silently
re-grants execution that a resident may have revoked.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

MANIFEST = 'house-hooks-v1.json'


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
        if record.get('status') != 'complete':
            raise RuntimeError('Incomplete hook migration; operator review required (no grants replayed)')
        return
    sources = []
    for path, prefix, scoped in [
        (Path(global_source) if global_source else home / 'hooks.json', 'house-global-v1', False),
        (project / '.chaos/hooks.json', 'house-project-v1', True),
    ]:
        if path.exists():
            content = path.read_bytes()
            data = json.loads(content)
            # House bookkeeping is not part of Chaos's strict legacy schema.
            # Strip only our known key; retain all hook definitions unchanged.
            data.pop('_helixkit_managed', None)
            if data == {'hooks': {}} or (set(data) == {'hooks'} and
                    all(groups == [] for groups in data['hooks'].values())):
                continue
            imported = home / (prefix + '-import.json')
            save(imported, data)
            sources.append({'path': str(path), 'prefix': prefix, 'project': scoped,
                            'sha256': hashlib.sha256(content).hexdigest(), 'import_path': str(imported)})
    existing = json.loads(run(home, project, 'list'))
    if any(row['id'].startswith(('house-global-v1-', 'house-project-v1-')) for row in existing):
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


def main():
    home = Path(os.environ.get('CHAOS_HOME', str(Path.home() / '.chaos')))
    project = Path(os.environ['AGENT_REPO_PATH'])
    prepare(home, project)
    oauth = home / 'oauth-runtime'
    if oauth.is_dir():
        prepare(oauth, project, global_source=home / 'hooks.json')
    print('Chaos database hooks ready')


if __name__ == '__main__':
    main()
