"""Exercise the real downloader against controlled transport fixtures."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'agent-runtime/install-chaos-binary'
REVISION = 'a' * 40


class ChaosBinaryInstallTest(unittest.TestCase):
    def run_install(self, *, revision=REVISION, arch='amd64', manifest=REVISION,
                    corrupt=False, missing=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            asset = root / 'fixture.tar.gz'
            with tarfile.open(asset, 'w:gz') as archive:
                for name in ('chaos', 'chaos_journald', 'alcatraz', 'chaos-forkve-wrapper', 'SOURCE_REVISION'):
                    data = (manifest + '\n' if name == 'SOURCE_REVISION' else '#!/bin/sh\necho fixture-chaos\n').encode()
                    info = tarfile.TarInfo('./' + name)
                    info.size, info.mode = len(data), 0o755
                    archive.addfile(info, io.BytesIO(data))
            digest = '0' * 64 if corrupt else hashlib.sha256(asset.read_bytes()).hexdigest()
            (root / 'fixture.sha256').write_text(f'{digest}  chaos-linux-x86_64-{REVISION}.tar.gz\n')
            stub = root / 'curl'
            stub.write_text('''#!/bin/sh
set -eu
[ "$MISSING" != 1 ] || exit 22
for arg; do
  case "$arg" in https:*.sha256) source="$FIXTURE/fixture.sha256";;
    https:*.tar.gz) source="$FIXTURE/fixture.tar.gz";; esac
  destination=$arg
done
cp "$source" "$destination"
''')
            stub.chmod(0o755)
            destination = root / 'bin'
            result = subprocess.run([str(INSTALLER), 'https://github.com/seuros/chaos.git',
                                     revision, arch, str(destination)], text=True, capture_output=True,
                                    env={**os.environ, 'PATH': f'{root}:{os.environ["PATH"]}',
                                         'FIXTURE': tmp, 'MISSING': '1' if missing else '0'})
            installed = sorted(p.name for p in destination.glob('*'))
            return result, installed

    def test_installs_all_verified_runtime_binaries(self):
        result, installed = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(installed, ['chaos', 'chaos_journald'])
        self.assertIn('fixture-chaos', result.stdout)

    def test_rejects_corrupt_download_before_install(self):
        result, installed = self.run_install(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(installed, [])

    def test_rejects_wrong_source_before_install(self):
        result, installed = self.run_install(manifest='b' * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('revision mismatch', result.stderr)
        self.assertEqual(installed, [])

    def test_missing_build_is_not_a_silent_source_fallback(self):
        result, installed = self.run_install(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(installed, [])

    def test_invalid_revision_and_architecture_fail_before_download(self):
        for kwargs in ({'revision': 'master'}, {'revision': 'a' * 39}, {'arch': 'arm64'}):
            with self.subTest(kwargs=kwargs):
                result, installed = self.run_install(**kwargs)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(installed, [])


if __name__ == '__main__':
    unittest.main()
