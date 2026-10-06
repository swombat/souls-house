"""Conservative, standalone two-way Git sync; run only in a trusted home.

No credentials, hooks, scheduling or global Git configuration are installed.
All auto-commit scopes are protected against deletion and shrinking below half
their HEAD byte size, except explicitly allowed destructive scopes. Append-only
scopes never allow rewrites. Independent append additions are complete UTF-8
suffix blocks: retain each block verbatim, deduplicate identical blocks, retain
the longer prefix-contained extension, otherwise order whole blocks by UTF-8
bytes. Never reorder or deduplicate individual lines inside a block.
The common-dir advisory lock coordinates this runner, not arbitrary Git/editors.
"""
import argparse
from bisect import bisect_left
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import uuid

CONFIG_KEYS = ('auto_commit_paths', 'append_only_paths', 'allow_destructive_paths')
REASONS = {
    'not_recorded', 'runtime_unavailable', 'synced', 'lock_busy', 'staged_changes',
    'dirty_worktree', 'operation_in_progress', 'wrong_branch', 'invalid_configuration',
    'protected_deletion', 'protected_shrink', 'append_only_violation',
    'commit_failed', 'fetch_failed', 'merge_conflict', 'integration_failed',
    'push_failed', 'timed_out', 'runner_failed', 'stale',
}


class Refused(Exception):
    def __init__(self, reason, state='blocked'):
        self.reason, self.state = reason, state


def contains(scope, path):
    return path == scope or path.startswith(scope + '/')


def validate_configuration(config):
    if not isinstance(config, dict) or set(config) - set(CONFIG_KEYS):
        raise ValueError('unsupported standard_sync configuration')
    result = {}
    for key in CONFIG_KEYS:
        paths = config.get(key, [])
        if not isinstance(paths, list) or len(paths) > 100:
            raise ValueError('standard_sync paths must be a bounded array')
        for path in paths:
            if (not isinstance(path, str) or not path or len(path) > 1024 or
                    any(ord(c) < 32 for c in path) or '\\' in path or
                    path.startswith('/') or any(p in ('', '.', '..', '.git') for p in path.split('/')) or
                    any(c in path for c in '*?[')):
                raise ValueError('standard_sync paths must be literal relative scopes')
        result[key] = sorted(set(paths))
    for key in CONFIG_KEYS[1:]:
        if any(not any(contains(scope, path) for scope in result['auto_commit_paths'])
               for path in result[key]):
            raise ValueError('policy scopes must be within auto_commit_paths')
    return result


def now():
    return datetime.now(timezone.utc).isoformat()


class Sync:
    def __init__(self, root, branch, config):
        self.root = Path(root).resolve()
        self.branch = branch
        self.config = validate_configuration(config)
        self.deadline = time.monotonic() + 180
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith('GIT_') and key not in ('GIT_ASKPASS', 'GIT_SSH_COMMAND', 'GIT_SSH'):
                self.env.pop(key)
        self.env.update(GIT_TERMINAL_PROMPT='0', GIT_LITERAL_PATHSPECS='1')

    def git(self, *args, reason='runner_failed', acceptable=(0,)):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Refused('timed_out', 'failed')
        command = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                   '-c', 'commit.gpgsign=false', '-c', 'merge.gpgsign=false',
                   '-c', 'user.name=Home sync', '-c', 'user.email=home-sync@localhost', *args]
        process = subprocess.Popen(command, cwd=self.root, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            out, _err = process.communicate(timeout=min(60, remaining))
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise Refused('timed_out', 'failed')
        if process.returncode not in acceptable:
            raise Refused(reason, 'failed')
        return out, process.returncode

    def text(self, *args, **kwargs):
        return self.git(*args, **kwargs)[0].decode().strip()

    def paths(self, *args):
        return [os.fsdecode(p) for p in self.git(*args)[0].split(b'\0') if p]

    def matches(self, key, path):
        return any(contains(scope, path) for scope in self.config[key])

    def blob(self, revision, path):
        out, code = self.git('cat-file', 'blob', revision + ':' + path, acceptable=(0, 128))
        return out if code == 0 else None

    def check_append(self, base, value):
        base = base or b''
        if value is None or not value.startswith(base):
            raise Refused('append_only_violation', 'needs_attention')
        for data in (base, value):
            if b'\0' in data or (data and not data.endswith(b'\n')):
                raise Refused('append_only_violation', 'needs_attention')
            try:
                data.decode('utf-8')
            except UnicodeDecodeError:
                raise Refused('append_only_violation', 'needs_attention')

    def protect(self, base, value, path):
        if self.matches('append_only_paths', path):
            self.check_append(base, b'' if base is None and value is None else value)
        if base is not None and not self.matches('allow_destructive_paths', path):
            if value is None:
                raise Refused('protected_deletion', 'needs_attention')
            if len(value) * 2 < len(base):
                raise Refused('protected_shrink', 'needs_attention')

    def clean_preflight(self):
        git_dir = Path(self.text('rev-parse', '--absolute-git-dir'))
        if any((git_dir / p).exists() for p in
               ('index.lock', 'HEAD.lock', 'MERGE_HEAD', 'rebase-merge', 'rebase-apply',
                'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'sequencer')):
            raise Refused('operation_in_progress')
        if self.text('branch', '--show-current') != self.branch:
            raise Refused('wrong_branch')
        if self.paths('diff', '--cached', '--name-only', '-z'):
            raise Refused('staged_changes')

    def save_allowed_edits(self):
        self.clean_preflight()
        dirty = sorted(set(self.paths('diff', '--name-only', '--no-renames', '-z') +
                           self.paths('ls-files', '--others', '--exclude-standard', '-z')))
        if any(not self.matches('auto_commit_paths', path) for path in dirty):
            raise Refused('dirty_worktree')
        for path in dirty:
            target = self.root / path
            if target.is_symlink() or not target.resolve().is_relative_to(self.root):
                raise Refused('invalid_configuration')
            value = target.read_bytes() if target.exists() else None
            self.protect(self.blob('HEAD', path), value, path)
        if dirty:
            # Literal, enumerated paths only. --only cannot include someone
            # else's newly staged files in our commit.
            self.git('add', '--', *dirty, reason='commit_failed')
            self.git('commit', '--only', '-m', 'Save approved home changes', '--', *dirty,
                     reason='commit_failed')
        self.clean_preflight()
        if self.paths('diff', '--name-only', '-z') or self.paths('ls-files', '--others', '--exclude-standard', '-z'):
            raise Refused('dirty_worktree')

    def append_merges(self, base, local, remote):
        changed = set(self.paths('diff', '--name-only', '--no-renames', '-z', base, local) +
                      self.paths('diff', '--name-only', '--no-renames', '-z', base, remote))
        merged = {}
        for path in sorted(changed):
            if self.matches('auto_commit_paths', path):
                self.protect(self.blob(base, path), self.blob(local, path), path)
                self.protect(self.blob(base, path), self.blob(remote, path), path)
            if not self.matches('append_only_paths', path):
                continue
            base_blob = self.blob(base, path)
            old = base_blob or b''
            ours, theirs = self.blob(local, path), self.blob(remote, path)
            if base_blob is None:
                ours, theirs = ours or b'', theirs or b''
            self.check_append(old, ours)
            self.check_append(old, theirs)
            ours_suffix, theirs_suffix = ours[len(old):], theirs[len(old):]
            if ours_suffix.startswith(theirs_suffix):
                additions = ours_suffix
            elif theirs_suffix.startswith(ours_suffix):
                additions = theirs_suffix
            else:
                additions = b''.join(sorted((ours_suffix, theirs_suffix)))
            merged[path] = old + additions
        return merged

    def integrate(self):
        self.git('fetch', '--no-tags', 'origin', 'refs/heads/' + self.branch, reason='fetch_failed')
        local = self.text('rev-parse', 'HEAD')
        remote = self.text('rev-parse', 'FETCH_HEAD')
        base = self.text('merge-base', local, remote, reason='integration_failed')
        merge_paths = set(self.paths('diff', '--name-only', '--no-renames', '-z', base, local) +
                          self.paths('diff', '--name-only', '--no-renames', '-z', base, remote))
        try:
            # --no-overwrite-ignore is insufficient on some non-fast-forward
            # merge paths. Refuse collisions explicitly before any checkout.
            ignored = self.paths('ls-files', '--others', '--ignored', '--exclude-standard', '-z')
            incoming = sorted(self.paths('ls-tree', '-r', '--name-only', '-z', remote))
            tracked_paths = set(incoming)
            for private in ignored:
                parts = private.split('/')
                descendant = bisect_left(incoming, private + '/')
                if (any('/'.join(parts[:end]) in tracked_paths for end in range(1, len(parts) + 1)) or
                        (descendant < len(incoming) and incoming[descendant].startswith(private + '/'))):
                    raise Refused('dirty_worktree', 'needs_attention')
            append = self.append_merges(base, local, remote)
        except Refused as failure:
            # No merge has started; local commits already remain intact.
            failure.rescue = True
            raise
        _out, ancestor = self.git('merge-base', '--is-ancestor', remote, local, acceptable=(0, 1))
        if ancestor == 0:
            return
        # --no-ff leaves integration uncommitted so append resolution is also
        # deterministic for truly divergent histories. A descendant already
        # contains our exact base; do not create an empty merge on each body.
        try:
            if base == local:
                self.git('merge', '--ff-only', '--no-overwrite-ignore', remote,
                         reason='integration_failed')
                return
            _out, code = self.git('merge', '--no-commit', '--no-ff', '--no-overwrite-ignore', remote,
                                  reason='integration_failed', acceptable=(0, 1))
            conflicts = self.paths('diff', '--name-only', '--diff-filter=U', '-z')
            if any(path not in append for path in conflicts):
                raise Refused('merge_conflict', 'needs_attention')
            if code and not conflicts:
                raise Refused('integration_failed', 'needs_attention')
            for path, value in append.items():
                target = self.root / path
                if target.is_symlink() or not target.resolve().is_relative_to(self.root):
                    raise Refused('invalid_configuration', 'needs_attention')
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(value)
                self.git('add', '--', path, reason='integration_failed')
            if set(self.paths('diff', '--cached', '--name-only', '-z')) - merge_paths:
                raise Refused('staged_changes', 'needs_attention')
            if self.paths('diff', '--name-only', '-z'):
                raise Refused('dirty_worktree', 'needs_attention')
            self.git('commit', '-m', 'Integrate home changes', reason='integration_failed')
        except Refused as failure:
            # Never reset/stash; Git abort restores the pre-merge local commits.
            self.deadline = time.monotonic() + 60
            try:
                git_dir = Path(self.text('rev-parse', '--absolute-git-dir'))
                if (git_dir / 'MERGE_HEAD').exists():
                    self.git('merge', '--abort', reason='integration_failed')
            except Refused:
                failure.reason = 'integration_failed'
            failure.rescue = True
            failure.state = 'needs_attention'
            raise

    def rescue(self, status):
        self.deadline = time.monotonic() + 60
        sha = self.text('rev-parse', 'HEAD')
        cached_ref = status.get('rescued_ref')
        if (status.get('rescued_sha') == sha and isinstance(cached_ref, str) and
                re.fullmatch(r'rescue/[A-Za-z0-9_-]{1,48}/[0-9]{8}T[0-9]{12}Z-[a-f0-9]{12}', cached_ref)):
            # A status-file pair alone is not evidence the remote still holds
            # this commit. Never reuse a missing/moved/mismatched rescue ref.
            try:
                remote = self.text('ls-remote', '--refs', 'origin', 'refs/heads/' + cached_ref,
                                   reason='push_failed')
            except Refused:
                return cached_ref, 'failed'
            if remote == sha + '\trefs/heads/' + cached_ref:
                return cached_ref, 'pushed'
        host = re.sub('[^a-zA-Z0-9_-]', '-', socket.gethostname())[:48] or 'local'
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        ref = f'rescue/{host}/{stamp}-{uuid.uuid4().hex[:12]}'
        try:
            self.git('push', '--no-verify', 'origin', sha + ':refs/heads/' + ref, reason='push_failed')
            status.update(rescued_sha=sha, rescued_ref=ref)
            return ref, 'pushed'
        except Refused:
            return ref, 'failed'

    def run(self):
        self.git('check-ref-format', '--branch', self.branch, reason='invalid_configuration')
        if Path(self.text('rev-parse', '--show-toplevel')).resolve() != self.root:
            raise Refused('invalid_configuration')
        common = Path(self.text('rev-parse', '--git-common-dir'))
        if not common.is_absolute():
            common = self.root / common
        common = common.resolve()
        status_path = common / 'standard-home-sync-status.json'
        with (common / 'standard-home-sync.lock').open('a') as lock:
            busy = False
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                busy = True
            try:
                previous = json.loads(status_path.read_text())
                if not isinstance(previous, dict):
                    previous = {}
            except (OSError, ValueError):
                previous = {}
            status = dict(state='unknown', checked_at=now(), last_success_at=previous.get('last_success_at'),
                          reason_code='not_recorded', rescue_ref=None, rescue_status='not_needed',
                          rescued_sha=None, rescued_ref=None)
            saved_sha, saved_ref = previous.get('rescued_sha'), previous.get('rescued_ref')
            if (isinstance(saved_sha, str) and re.fullmatch(r'[0-9a-f]{40}', saved_sha) and
                    isinstance(saved_ref, str) and
                    re.fullmatch(r'rescue/[A-Za-z0-9_-]{1,48}/[0-9]{8}T[0-9]{12}Z-[a-f0-9]{12}', saved_ref)):
                status.update(rescued_sha=saved_sha, rescued_ref=saved_ref)
            if busy:
                status.update(state='busy', reason_code='lock_busy')
                return status, 75  # do not overwrite the active runner's status
            try:
                self.save_allowed_edits()
                self.integrate()
                self.clean_preflight()
                if self.paths('diff', '--name-only', '-z'):
                    raise Refused('dirty_worktree')
                self.git('push', '--no-verify', 'origin', 'HEAD:refs/heads/' + self.branch, reason='push_failed')
                status.update(state='ok', reason_code='synced', last_success_at=now())
                code = 0
            except Refused as failure:
                status.update(state=failure.state, reason_code=failure.reason)
                if getattr(failure, 'rescue', False):
                    status['rescue_ref'], status['rescue_status'] = self.rescue(status)
                code = 1
            status['checked_at'] = now()
            with tempfile.NamedTemporaryFile(mode='w', dir=common, delete=False) as stream:
                json.dump(status, stream, sort_keys=True)
                temporary = stream.name
            os.replace(temporary, status_path)
            return status, code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--branch', required=True)
    for key in CONFIG_KEYS:
        parser.add_argument('--' + key.replace('_paths', '_path').replace('_', '-'),
                            action='append', default=[], dest=key)
    args = vars(parser.parse_args())
    root, branch = args.pop('root'), args.pop('branch')
    try:
        status, code = Sync(root, branch, args).run()
    except (ValueError, OSError, Refused):
        status = dict(state='failed', checked_at=now(), last_success_at=None,
                      reason_code='invalid_configuration', rescue_ref=None, rescue_status='not_needed')
        code = 1
    print(json.dumps(status, sort_keys=True))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
