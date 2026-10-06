"""Real, isolated Git fixtures. No network, residents or private homes."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
import standard_home_sync as standard


class StandardHomeSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.remote = self.base / 'origin.git'
        self.home = self.base / 'home'
        self.peer = self.base / 'peer'
        self.env = {'PATH': os.environ['PATH'], 'HOME': str(self.base),
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
        self.git(self.base, 'init', '--bare', '--initial-branch=main', str(self.remote))
        self.git(self.base, 'clone', str(self.remote), str(self.home))
        self.configure(self.home)
        (self.home / 'journal.txt').write_text('base\n')
        (self.home / 'identity.txt').write_text('identity protected contents\n' * 10)
        self.commit(self.home, 'initial')
        self.git(self.home, 'push', 'origin', 'main')
        self.git(self.base, 'clone', str(self.remote), str(self.peer))
        self.configure(self.peer)
        self.config = {'auto_commit_paths': ['journal.txt', 'identity.txt'],
                       'append_only_paths': ['journal.txt']}

    def git(self, root, *args):
        result = subprocess.run(['git', *args], cwd=root, env=self.env,
                                capture_output=True, check=True)
        return result.stdout.decode().strip()

    def configure(self, root):
        self.git(root, 'config', 'user.name', 'Synthetic')
        self.git(root, 'config', 'user.email', 'synthetic@example.invalid')

    def commit(self, root, message):
        self.git(root, 'add', 'journal.txt', 'identity.txt')
        self.git(root, 'commit', '-m', message)

    def run_sync(self, config=None):
        from unittest.mock import patch
        with patch.dict(os.environ, self.env, clear=True):
            return standard.Sync(self.home, 'main', self.config if config is None else config).run()

    def test_committed_changes_only_default_and_confirmed_success(self):
        (self.home / 'journal.txt').write_text('base\nlocal\n')
        self.commit(self.home, 'local')
        status, code = self.run_sync({})
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertIsNotNone(status['last_success_at'])
        self.assertEqual(self.git(self.home, 'rev-parse', 'HEAD'),
                         self.git(self.remote, 'rev-parse', 'main'))
        (self.home / 'journal.txt').write_text('base\nlocal\nunsaved\n')
        status, code = self.run_sync({})
        self.assertEqual((code, status['reason_code']), (1, 'dirty_worktree'))
        self.assertIsNotNone(status['last_success_at'])

    def test_only_explicit_allowlisted_edits_and_no_hooks(self):
        marker = self.base / 'HOOK-RAN'
        hooks = self.home / '.git/hooks'
        for name in ('pre-commit', 'post-commit', 'pre-push', 'post-merge'):
            file = hooks / name
            file.write_text(f'#!/bin/sh\ntouch "{marker}"\nexit 1\n')
            file.chmod(0o755)
        (self.home / 'journal.txt').write_text('base\nsaved\n')
        status, code = self.run_sync()
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertFalse(marker.exists())
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

    def test_excluded_private_dirt_refuses_without_staging_or_rescue(self):
        (self.home / 'private.txt').write_text('synthetic private data')
        (self.home / 'journal.txt').write_text('base\npending\n')
        head = self.git(self.home, 'rev-parse', 'HEAD')
        status, code = self.run_sync()
        self.assertEqual((code, status['reason_code'], status['rescue_status']),
                         (1, 'dirty_worktree', 'not_needed'))
        self.assertEqual(head, self.git(self.home, 'rev-parse', 'HEAD'))
        self.assertEqual(self.git(self.home, 'diff', '--cached', '--name-only'), '')
        self.assertEqual(self.git(self.remote, 'for-each-ref', '--format=%(refname)', 'refs/heads/rescue'), '')

    def test_staged_changes_and_git_operations_preserved(self):
        (self.home / 'journal.txt').write_text('base\nstaged\n')
        self.git(self.home, 'add', 'journal.txt')
        before = self.git(self.home, 'diff', '--cached')
        status, _code = self.run_sync()
        self.assertEqual(status['reason_code'], 'staged_changes')
        self.assertEqual(before, self.git(self.home, 'diff', '--cached'))
        self.git(self.home, 'reset', '--', 'journal.txt')  # fixture cleanup only
        (self.home / '.git/index.lock').write_text('')
        status, _code = self.run_sync()
        self.assertEqual(status['reason_code'], 'operation_in_progress')

    def test_lock_busy_and_worktree_common_lock(self):
        lock = self.home / '.git/standard-home-sync.lock'
        with lock.open('w') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            status, code = self.run_sync()
            worktree = self.base / 'worktree'
            self.git(self.home, 'worktree', 'add', '-b', 'side', str(worktree))
            from unittest.mock import patch
            with patch.dict(os.environ, self.env, clear=True):
                alternate, alternate_code = standard.Sync(worktree, 'side', {}).run()
        self.assertEqual((code, status['state'], status['reason_code']), (75, 'busy', 'lock_busy'))
        self.assertEqual((alternate_code, alternate['reason_code']), (75, 'lock_busy'))

    def test_protected_deletion_and_shrink_leave_edits_uncommitted(self):
        path = self.home / 'identity.txt'
        original = path.read_text()
        for value, reason in ((None, 'protected_deletion'), ('tiny', 'protected_shrink')):
            if value is None:
                path.unlink()
            else:
                path.write_text(value)
            status, code = self.run_sync()
            self.assertEqual((code, status['state'], status['reason_code']),
                             (1, 'needs_attention', reason))
            self.assertEqual(self.git(self.home, 'diff', '--cached', '--name-only'), '')
            self.assertEqual(status['rescue_status'], 'not_needed')
            path.write_text(original)

    def test_explicit_destructive_allowance_and_exact_half_threshold(self):
        path = self.home / 'identity.txt'
        original = path.read_bytes()
        path.write_bytes(original[:len(original) // 2])
        status, code = self.run_sync()
        self.assertEqual(code, 0)
        path.unlink()
        config = dict(self.config, allow_destructive_paths=['identity.txt'])
        status, code = self.run_sync(config)
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertFalse(path.exists())

    def test_append_rewrite_and_truncation_refused_despite_allowance(self):
        config = dict(self.config, allow_destructive_paths=['journal.txt'])
        for value in ('rewritten\n', 'ba', ''):
            (self.home / 'journal.txt').write_text(value)
            status, code = self.run_sync(config)
            self.assertEqual((code, status['reason_code']), (1, 'append_only_violation'))

    def test_independent_append_merge_is_deterministic_deduplicated(self):
        (self.home / 'journal.txt').write_text('base\nzebra\nshared\n')
        (self.peer / 'journal.txt').write_text('base\nalpha\nshared\n')
        self.commit(self.peer, 'peer append')
        self.git(self.peer, 'push', 'origin', 'main')
        status, code = self.run_sync()
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertEqual((self.home / 'journal.txt').read_text(), 'base\nalpha\nshared\nzebra\n')
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

    def test_new_independent_append_files_are_not_mistaken_for_deletions(self):
        config = {'auto_commit_paths': ['journals'], 'append_only_paths': ['journals']}
        (self.home / 'journals').mkdir()
        (self.home / 'journals/local.md').write_text('local\n')
        (self.peer / 'journals').mkdir()
        (self.peer / 'journals/remote.md').write_text('remote\n')
        self.git(self.peer, 'add', 'journals/remote.md')
        self.git(self.peer, 'commit', '-m', 'new journal')
        self.git(self.peer, 'push', 'origin', 'main')
        status, code = self.run_sync(config)
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertEqual((self.home / 'journals/local.md').read_text(), 'local\n')
        self.assertEqual((self.home / 'journals/remote.md').read_text(), 'remote\n')

    def test_remote_protected_shrink_is_preserved_without_integrating(self):
        (self.peer / 'identity.txt').write_text('tiny')
        self.commit(self.peer, 'remote shrink')
        self.git(self.peer, 'push', 'origin', 'main')
        original = (self.home / 'identity.txt').read_text()
        status, code = self.run_sync()
        self.assertEqual((code, status['reason_code'], status['rescue_status']),
                         (1, 'protected_shrink', 'pushed'))
        self.assertEqual((self.home / 'identity.txt').read_text(), original)

    def conflicting_commits(self):
        (self.home / 'identity.txt').write_text('local conflict\n' * 30)
        self.commit(self.home, 'local conflict')
        local = self.git(self.home, 'rev-parse', 'HEAD')
        (self.peer / 'identity.txt').write_text('remote conflict\n' * 30)
        self.commit(self.peer, 'remote conflict')
        self.git(self.peer, 'push', 'origin', 'main')
        return local, self.git(self.remote, 'rev-parse', 'main')

    def test_other_conflict_aborts_preserves_commits_and_rescues(self):
        local, upstream = self.conflicting_commits()
        status, code = self.run_sync()
        self.assertEqual((code, status['state'], status['reason_code'], status['rescue_status']),
                         (1, 'needs_attention', 'merge_conflict', 'pushed'))
        self.assertEqual(local, self.git(self.home, 'rev-parse', 'HEAD'))
        self.assertEqual(local, self.git(self.remote, 'rev-parse', status['rescue_ref']))
        self.assertEqual(upstream, self.git(self.remote, 'rev-parse', 'main'))
        self.assertIsNone(status['last_success_at'])
        self.assertFalse((self.home / '.git/MERGE_HEAD').exists())
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

    def test_rescue_failure_is_separate_from_primary_conflict(self):
        local, _upstream = self.conflicting_commits()
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n'); hook.chmod(0o755)
        status, code = self.run_sync()
        self.assertEqual((code, status['reason_code'], status['rescue_status']),
                         (1, 'merge_conflict', 'failed'))
        self.assertEqual(local, self.git(self.home, 'rev-parse', 'HEAD'))
        self.assertIsNone(status['last_success_at'])

    def test_committed_remote_append_rewrite_refuses_and_rescues(self):
        (self.peer / 'journal.txt').write_text('remote rewrite\n')
        self.commit(self.peer, 'unsafe append rewrite')
        self.git(self.peer, 'push', 'origin', 'main')
        head = self.git(self.home, 'rev-parse', 'HEAD')
        status, code = self.run_sync()
        self.assertEqual((code, status['reason_code'], status['rescue_status']),
                         (1, 'append_only_violation', 'pushed'))
        self.assertEqual(head, self.git(self.home, 'rev-parse', 'HEAD'))

    def test_invalid_scopes_and_policy_escape(self):
        for path in ('.', '..', '.git/config', 'notes/../private', '/absolute', 'notes/*', 'notes//a'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                standard.validate_configuration({'auto_commit_paths': [path]})
        with self.assertRaises(ValueError):
            standard.validate_configuration({'append_only_paths': ['outside']})

    def test_real_local_cli_emits_bounded_json(self):
        result = subprocess.run([sys.executable, str(RUNTIME / 'standard_home_sync.py'),
                                 '--root', str(self.home), '--branch', 'main'],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['reason_code'], 'synced')
        self.assertNotIn(str(self.home), result.stdout)


if __name__ == '__main__':
    unittest.main()
