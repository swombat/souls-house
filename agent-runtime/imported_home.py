"""Opt-in portable home validation. Stock residents never enter this path.

"Imported" is a class of home profile. Each imported profile names the
environment variable that holds its root and, optionally, a compatibility
default for its sync script. An unknown profile is an error everywhere: it
never falls back to the house path or to another resident's profile.
"""
import json
import os
import sqlite3
from pathlib import Path
import sys

HOUSE_PROFILE = 'house'
# mira_v1 keeps its original contract byte for byte: MIRA_ROOT, and the sync
# script at the path her home already has. portable_v1 is the neutral form.
IMPORTED_PROFILES = {
    'mira_v1': {
        'root_env': 'MIRA_ROOT',
        'default_sync': 'shared/automation/scripts/git_sync.py',
    },
    'portable_v1': {
        'root_env': 'SOULSHOUSE_HOME_ROOT',
        'default_sync': None,
    },
}
MANIFEST_FILE_KEYS = ('instructions', 'soul', 'narrative', 'hooks', 'journal_reader')


def profile():
    value = os.environ.get('SOULSHOUSE_HOME_PROFILE') or HOUSE_PROFILE
    if value != HOUSE_PROFILE and value not in IMPORTED_PROFILES:
        raise ValueError(f'unknown resident home profile: {value!r}')
    return value


def enabled():
    return profile() != HOUSE_PROFILE


def home_class():
    return 'imported' if enabled() else 'house'


def root_env_name(selected=None):
    selected = selected or profile()
    if selected not in IMPORTED_PROFILES:
        raise ValueError(f'profile {selected!r} is not an imported home profile')
    return IMPORTED_PROFILES[selected]['root_env']


def home_root():
    name = root_env_name()
    value = os.environ.get(name)
    if not value:
        raise ValueError(f'{name} must name the imported home root')
    return Path(value).resolve()


def home_file(root, relative, key, allow_parent_segments=True):
    """Resolve a manifest path that must be a non-empty file inside root.

    `resolve()` follows symlinks before the containment check, so a link that
    points outside the home is rejected as an escape.
    """
    root = Path(root).resolve()
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError('home paths must be relative')
    if not allow_parent_segments and '..' in Path(relative).parts:
        raise ValueError(f'home path for {key} must not traverse with ..')
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise ValueError(f'home path for {key} escapes the imported home') from error
    if not path.is_file() or not path.stat().st_size:
        raise ValueError(f'missing imported home component: {key}')
    return path


def sync_relative_path(manifest, selected=None):
    """Return the manifest's sync script path, or the profile's documented default."""
    selected = selected or profile()
    if 'sync' in manifest:
        return manifest['sync']
    return IMPORTED_PROFILES[selected]['default_sync']


def sync_script(root, manifest, selected=None):
    relative = sync_relative_path(manifest, selected)
    if relative is None:
        raise ValueError('imported home manifest does not declare a sync script')
    path = home_file(root, relative, 'sync', allow_parent_segments=False)
    if path.suffix != '.py':
        raise ValueError('imported home sync script must be a Python file')
    return path


def home_state_path(root, relative, key):
    """Resolve a manifest path to a file the resident writes, inside root.

    Unlike home_file, the file need not exist yet. Symlinks in the existing
    part of the path are followed before the containment check.
    """
    root = Path(root).resolve()
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError(f'home path for {key} must be relative')
    if '..' in Path(relative).parts:
        raise ValueError(f'home path for {key} must not traverse with ..')
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise ValueError(f'home path for {key} escapes the imported home') from error
    if path == root or path.is_dir():
        raise ValueError(f'home path for {key} must name a file')
    return path


def sync_status_path(root, manifest):
    """The resident's own sync status file, or None when the manifest declares none."""
    if 'sync_status' not in manifest:
        return None
    return home_state_path(root, manifest['sync_status'], 'sync_status')


def validate(root=None):
    selected = profile()
    if selected == HOUSE_PROFILE:
        raise ValueError('house residents have no imported home to validate')
    root = Path(root).resolve() if root else home_root()
    manifest = json.loads((root / 'resident-home.json').read_text())
    if manifest.get('format') != 'souls-home/v1' or manifest.get('profile') != selected:
        raise ValueError('unsupported imported home manifest')
    if manifest.get('identity_id') != os.environ.get('SOULSHOUSE_PORTABLE_HOME_ID'):
        raise ValueError('portable identity does not match the provisioned resident')
    if manifest.get('graph') != 'external':
        raise ValueError('imported home profile requires its existing external graph')
    for key in MANIFEST_FILE_KEYS:
        home_file(root, manifest.get(key), key)
    if 'sync' in manifest or IMPORTED_PROFILES[selected]['default_sync'] is None:
        # An explicit sync path is part of the manifest contract. A profile
        # with no compatibility default must declare one. mira_v1's default is
        # checked by the sync loop instead, so her turns do not change.
        sync_script(root, manifest, selected)
    if 'sync_status' in manifest:
        sync_status_path(root, manifest)
    hooks = json.loads((root / manifest['hooks']).read_text()).get('hooks', {})
    if not all(name in hooks for name in ('SessionStart', 'BeforeTurn', 'Stop')):
        raise ValueError('imported home requires its own wake and memory hooks')
    return root, manifest


def check_project_trust(root, chaos_home, unreadable_message, untrusted_message):
    # The pinned Chaos runtime keeps project trust here, not in config.toml.
    # Without it the project's config *and hooks* are silently disabled.
    database = Path(chaos_home) / 'chaos.sqlite'
    try:
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as db:
            row = db.execute('SELECT trust_level FROM project_trust WHERE project_path = ?',
                             (str(Path(root).resolve()),)).fetchone()
    except sqlite3.Error as error:
        raise ValueError(unreadable_message) from error
    if row != ('trusted',):
        raise ValueError(untrusted_message)


def require_runtime_trust(root, chaos_home):
    check_project_trust(
        root, chaos_home,
        'Review and trust the imported root in Chaos before a resident turn',
        'Imported home is not trusted in Chaos; its wake hooks would not run',
    )


def main(argv):
    if argv[1:] == ['--class']:
        print(home_class())
        return 0
    if argv[1:] == ['--root']:
        print(home_root())
        return 0
    if enabled():
        validate()
        print('imported home validated')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (ValueError, KeyError, OSError) as error:
        print(f'imported home check failed: {error}', file=sys.stderr)
        sys.exit(1)
