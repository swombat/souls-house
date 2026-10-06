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

    def run_sync(self, config=None, root=None):
        from unittest.mock import patch
        with patch.dict(os.environ, self.env, clear=True):
            return standard.Sync(root or self.home, 'main', self.config if config is None else config).run()

    def rescue_refs(self):
        return self.git(self.remote, 'for-each-ref', '--format=%(refname)', 'refs/heads/rescue').splitlines()

    def test_idle_alternating_clones_add_no_commits_after_one_append(self):
        (self.home / 'journal.txt').write_text('base\n## New entry\n\nBody.\n\n')
        self.assertEqual(self.run_sync()[1], 0)
        expected = self.git(self.remote, 'rev-parse', 'main')
        count = self.git(self.remote, 'rev-list', '--count', 'main')
        for _cycle in range(8):
            for root in (self.peer, self.home):
                status, code = self.run_sync(root=root)
                self.assertEqual((code, status['state']), (0, 'ok'))
                self.assertEqual(self.git(root, 'rev-parse', 'HEAD'), expected)
                self.assertEqual(self.git(self.remote, 'rev-list', '--count', 'main'), count)

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

    def test_independent_append_merge_preserves_each_suffix_verbatim(self):
        (self.home / 'journal.txt').write_text('base\nzebra\nshared\n')
        (self.peer / 'journal.txt').write_text('base\nalpha\nshared\n')
        self.commit(self.peer, 'peer append')
        self.git(self.peer, 'push', 'origin', 'main')
        status, code = self.run_sync()
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertEqual((self.home / 'journal.txt').read_text(), 'base\nalpha\nshared\nzebra\nshared\n')
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

    def assert_append_merge(self, ours, theirs, expected):
        base = '# Existing entry\n\nExisting body.\n\n'
        (self.home / 'journal.txt').write_text(base)
        self.commit(self.home, 'shared multiline base')
        self.git(self.home, 'push', 'origin', 'main')
        self.git(self.peer, 'pull', '--ff-only', 'origin', 'main')
        (self.home / 'journal.txt').write_text(base + ours)
        (self.peer / 'journal.txt').write_text(base + theirs)
        if theirs:
            self.commit(self.peer, 'peer multiline append')
            self.git(self.peer, 'push', 'origin', 'main')
        status, code = self.run_sync()
        self.assertEqual((code, status['state']), (0, 'ok'))
        self.assertEqual((self.home / 'journal.txt').read_text(), base + expected)
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

    def test_multiline_divergent_suffixes_keep_headings_body_and_repeated_blanks(self):
        ours = '## Zebra entry\n\nBody first.\nRepeated.\nRepeated.\n\n\nBody last.\n\n'
        theirs = '## Alpha entry\n\nFirst.\n\n\nSecond.\nRepeated.\nRepeated.\n\n'
        self.assert_append_merge(ours, theirs, theirs + ours)

    def test_single_sided_remote_append_is_not_reordered_during_integration(self):
        suffix = '## Heading\n\nZebra body.\nAlpha body.\nRepeated.\nRepeated.\n\n\n'
        self.assert_append_merge('', suffix, suffix)

    def test_single_sided_local_append_is_not_reordered(self):
        suffix = '## Heading\n\nZebra body.\nAlpha body.\nRepeated.\nRepeated.\n\n\n'
        self.assert_append_merge(suffix, '', suffix)

    def test_identical_multiline_suffix_is_deduplicated_only_as_a_whole_block(self):
        suffix = '## Same entry\n\nRepeated.\nRepeated.\n\n\nBody after blanks.\n\n'
        self.assert_append_merge(suffix, suffix, suffix)

    def test_prefix_contained_multiline_suffix_retains_longer_extension(self):
        suffix = '## Shared entry\n\nRepeated.\nRepeated.\n\n\n'
        longer = suffix + '## Next entry\n\nBody.\n\n'
        self.assert_append_merge(longer, suffix, longer)

    def test_remote_longer_prefix_extension_is_not_duplicated(self):
        suffix = '## Shared entry\n\nRepeated.\nRepeated.\n\n\n'
        longer = suffix + '## Next entry\n\nBody.\n\n'
        self.assert_append_merge(suffix, longer, longer)

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

    def test_repeated_conflict_reuses_verified_rescue_across_busy_and_failure(self):
        local, _upstream = self.conflicting_commits()
        first, _code = self.run_sync()
        self.assertEqual(first['rescued_sha'], local)
        self.assertEqual(first['rescued_ref'], first['rescue_ref'])
        # A verified cached rescue must not attempt another push.
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n'); hook.chmod(0o755)
        with (self.home / '.git/standard-home-sync.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy, code = self.run_sync()
            self.assertEqual(code, 75)
            self.assertEqual(busy['rescued_ref'], first['rescue_ref'])
        (self.home / 'excluded.txt').write_text('uncommitted synthetic private data')
        failed, code = self.run_sync()
        self.assertEqual((code, failed['reason_code']), (1, 'dirty_worktree'))
        self.assertEqual(failed['rescued_sha'], local)
        self.assertEqual(failed['rescued_ref'], first['rescue_ref'])
        (self.home / 'excluded.txt').unlink()
        for _cycle in range(4):
            status, code = self.run_sync()
            self.assertEqual((code, status['state'], status['rescue_status']),
                             (1, 'needs_attention', 'pushed'))
            self.assertEqual(status['rescue_ref'], first['rescue_ref'])
        self.assertEqual(self.rescue_refs(), ['refs/heads/' + first['rescue_ref']])

    def test_failed_rescue_can_retry_then_new_head_gets_new_rescue(self):
        self.conflicting_commits()
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n'); hook.chmod(0o755)
        failed, _code = self.run_sync()
        self.assertEqual(failed['rescue_status'], 'failed')
        self.assertIsNone(failed['rescued_sha'])
        hook.unlink()
        rescued, _code = self.run_sync()
        self.assertEqual(rescued['rescue_status'], 'pushed')
        self.assertEqual(len(self.rescue_refs()), 1)
        (self.home / 'journal.txt').write_text('base\nnew local commit\n')
        newer, _code = self.run_sync()
        self.assertEqual(newer['rescue_status'], 'pushed')
        self.assertNotEqual(newer['rescue_ref'], rescued['rescue_ref'])
        self.assertNotEqual(newer['rescued_sha'], rescued['rescued_sha'])
        self.assertEqual(newer['rescued_sha'], self.git(self.home, 'rev-parse', 'HEAD'))
        self.assertEqual(len(self.rescue_refs()), 2)

    def test_mismatched_cached_ref_and_sha_is_not_reused(self):
        self.conflicting_commits()
        first, _code = self.run_sync()
        (self.home / 'journal.txt').write_text('base\nnew committed head\n')
        self.commit(self.home, 'new head')
        head = self.git(self.home, 'rev-parse', 'HEAD')
        path = self.home / '.git/standard-home-sync-status.json'
        cached = json.loads(path.read_text())
        cached['rescued_sha'] = head  # ref still points to the previous commit
        path.write_text(json.dumps(cached))
        status, _code = self.run_sync()
        self.assertEqual(status['rescued_sha'], head)
        self.assertNotEqual(status['rescue_ref'], first['rescue_ref'])
        self.assertEqual(self.git(self.remote, 'rev-parse', status['rescue_ref']), head)

    def test_deleted_rescue_ref_is_not_reused(self):
        self.conflicting_commits()
        first, _code = self.run_sync()
        self.git(self.remote, 'update-ref', '-d', 'refs/heads/' + first['rescue_ref'])
        status, _code = self.run_sync()
        self.assertNotEqual(status['rescue_ref'], first['rescue_ref'])
        self.assertEqual(status['rescue_status'], 'pushed')
        self.assertEqual(len(self.rescue_refs()), 1)

    def test_success_keeps_rescue_cache_but_does_not_report_a_rescue_attempt(self):
        self.conflicting_commits()
        first, _code = self.run_sync()
        # Synthetic peer deliberately reconciles both histories, retaining its
        # own content. The home can now fast-forward without another commit.
        self.git(self.peer, 'fetch', 'origin', first['rescue_ref'])
        self.git(self.peer, 'merge', '-s', 'ours', 'FETCH_HEAD', '-m', 'manual reconciliation')
        self.git(self.peer, 'push', 'origin', 'main')
        status, code = self.run_sync()
        self.assertEqual((code, status['state'], status['rescue_status']), (0, 'ok', 'not_needed'))
        self.assertIsNone(status['rescue_ref'])
        self.assertEqual(status['rescued_sha'], first['rescued_sha'])
        self.assertEqual(status['rescued_ref'], first['rescued_ref'])
        self.assertEqual(len(self.rescue_refs()), 1)

    def test_ignored_private_file_collision_is_never_overwritten_or_published(self):
        self.assert_ignored_collision('private.txt', 'private.txt')

    def test_ignored_private_directory_cannot_be_replaced_by_remote_file(self):
        self.assert_ignored_collision('private/nested.txt', 'private')

    def test_ignored_private_file_cannot_be_replaced_by_remote_directory(self):
        self.assert_ignored_collision('private', 'private/nested.txt')

    def assert_ignored_collision(self, local_path, remote_path):
        (self.home / '.gitignore').write_text('private*\n')
        self.git(self.home, 'add', '.gitignore')
        self.git(self.home, 'commit', '-m', 'ignore local private file')
        self.git(self.home, 'push', 'origin', 'main')
        self.git(self.peer, 'pull', '--ff-only', 'origin', 'main')
        confirmed, code = self.run_sync({})
        self.assertEqual(code, 0)
        private = 'LOCAL PRIVATE SYNTHETIC CONTENT\n'
        local_file, remote_file = self.home / local_path, self.peer / remote_path
        local_file.parent.mkdir(parents=True, exist_ok=True)
        remote_file.parent.mkdir(parents=True, exist_ok=True)
        local_file.write_text(private)
        remote_file.write_text('REMOTE TRACKED CONTENT\n')
        self.git(self.peer, 'add', '-f', '--', remote_path)
        self.git(self.peer, 'commit', '-m', 'introduce tracked colliding path')
        self.git(self.peer, 'push', 'origin', 'main')
        head = self.git(self.home, 'rev-parse', 'HEAD')
        status, code = self.run_sync({})
        self.assertEqual((code, status['state'], status['reason_code']),
                         (1, 'needs_attention', 'dirty_worktree'))
        self.assertEqual(local_file.read_text(), private)
        self.assertEqual(self.git(self.home, 'rev-parse', 'HEAD'), head)
        self.assertEqual(status['last_success_at'], confirmed['last_success_at'])
        self.assertEqual(status['rescue_status'], 'pushed')
        self.assertEqual(self.git(self.remote, 'rev-parse', status['rescue_ref']), head)
        self.assertNotIn(local_path, self.git(self.remote, 'ls-tree', '-r', '--name-only', status['rescue_ref']))
        self.assertEqual(self.git(self.remote, 'show', 'main:' + remote_path), 'REMOTE TRACKED CONTENT')
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

    def test_rejected_primary_push_preserves_head_and_last_confirmed_success(self):
        confirmed, code = self.run_sync({})
        self.assertEqual(code, 0)
        upstream = self.git(self.remote, 'rev-parse', 'main')
        (self.home / 'journal.txt').write_text('base\nlocal committed changes\n')
        self.commit(self.home, 'local commit awaiting push')
        local = self.git(self.home, 'rev-parse', 'HEAD')
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n'); hook.chmod(0o755)
        status, code = self.run_sync({})
        self.assertEqual((code, status['state'], status['reason_code']),
                         (1, 'failed', 'push_failed'))
        self.assertEqual(status['last_success_at'], confirmed['last_success_at'])
        self.assertEqual(local, self.git(self.home, 'rev-parse', 'HEAD'))
        self.assertEqual(upstream, self.git(self.remote, 'rev-parse', 'main'))
        self.assertEqual(self.git(self.home, 'status', '--porcelain'), '')

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
