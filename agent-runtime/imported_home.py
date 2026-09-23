"""Opt-in portable home validation. Stock residents never enter this path."""
import json
import os
import sqlite3
from pathlib import Path
import sys


def enabled():
    return os.environ.get('SOULSHOUSE_HOME_PROFILE', 'house') == 'mira_v1'


def validate(root=None):
    root = Path(root or os.environ['MIRA_ROOT']).resolve()
    manifest = json.loads((root / 'resident-home.json').read_text())
    if manifest.get('format') != 'souls-home/v1' or manifest.get('profile') != 'mira_v1':
        raise ValueError('unsupported imported home manifest')
    if manifest.get('identity_id') != os.environ.get('SOULSHOUSE_PORTABLE_HOME_ID'):
        raise ValueError('portable identity does not match the provisioned resident')
    if manifest.get('graph') != 'external':
        raise ValueError('Mira profile requires her existing external graph')
    for key in ('instructions', 'soul', 'narrative', 'hooks', 'journal_reader'):
        relative = manifest[key]
        if not isinstance(relative, str) or Path(relative).is_absolute():
            raise ValueError('home paths must be relative')
        path = (root / relative).resolve()
        path.relative_to(root)
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f'missing imported home component: {key}')
    hooks = json.loads((root / manifest['hooks']).read_text()).get('hooks', {})
    if not all(name in hooks for name in ('SessionStart', 'BeforeTurn', 'Stop')):
        raise ValueError('imported home requires its own wake and memory hooks')
    return root, manifest


def require_runtime_trust(root, chaos_home):
    # The pinned Chaos runtime keeps project trust here, not in config.toml.
    # Without it the project's config *and hooks* are silently disabled.
    database = Path(chaos_home) / 'chaos.sqlite'
    try:
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as db:
            row = db.execute('SELECT trust_level FROM project_trust WHERE project_path = ?',
                             (str(Path(root).resolve()),)).fetchone()
    except sqlite3.Error as error:
        raise ValueError('Review and trust the imported root in Chaos before a resident turn') from error
    if row != ('trusted',):
        raise ValueError('Imported home is not trusted in Chaos; its wake hooks would not run')


if __name__ == '__main__':
    if enabled():
        validate()
        print('imported home validated')
