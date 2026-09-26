import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class MiraDevStartTest(unittest.TestCase):
    def test_git_credentials_are_repeatable_without_duplicate_helpers(self):
        script = (Path(__file__).resolve().parents[1] / 'agent-runtime/mira-dev-start').read_text()
        commands = '\n'.join(line for line in script.splitlines() if line.startswith('git config '))
        with tempfile.TemporaryDirectory() as home:
            env = {**os.environ, 'HOME': home, 'GIT_CONFIG_NOSYSTEM': '1',
                   'GIT_CONFIG_GLOBAL': str(Path(home) / '.gitconfig')}
            for _ in range(3):
                subprocess.run(['sh', '-ec', commands], env=env, check=True)
                helpers = subprocess.check_output(
                    ['git', 'config', '--global', '--get-all', 'credential.https://github.com.helper'],
                    env=env, text=True).splitlines()
                self.assertEqual(helpers, ['', '!/usr/bin/gh auth git-credential'])


if __name__ == '__main__':
    unittest.main()
