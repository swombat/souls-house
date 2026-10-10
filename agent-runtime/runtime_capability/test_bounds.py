import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from manifest import InvalidManifest, MAX_BYTES, MAX_DEPTH, read_manifest, validate


class BoundsTests(unittest.TestCase):
    def test_regular_and_oversized_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.yml"
            path.write_bytes(b"apt: []")
            self.assertEqual(validate(read_manifest(str(path))), ())
            path.write_bytes(b"x" * (MAX_BYTES + 1))
            with self.assertRaisesRegex(InvalidManifest, "^Invalid manifest$"):
                read_manifest(str(path))

    def test_absent_is_distinct_from_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.yml"
            with self.assertRaises(FileNotFoundError):
                read_manifest(str(path))
            path.touch()
            with self.assertRaises(InvalidManifest):
                validate(read_manifest(str(path)))

    def test_nonregular_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "target").write_bytes(b"apt: []")
            (root / "link").symlink_to(root / "target")
            os.mkfifo(root / "fifo")
            for path in (root, root / "link", root / "fifo"):
                with self.subTest(path=path):
                    with self.assertRaisesRegex(InvalidManifest, "^Invalid manifest$"):
                        read_manifest(str(path))

    def test_nesting_limit_before_construction(self):
        raw = ("apt: " + "[" * (MAX_DEPTH + 1) + "]" * (MAX_DEPTH + 1)).encode()
        with patch("manifest.yaml.load") as load:
            with self.assertRaisesRegex(InvalidManifest, "^Invalid manifest$"):
                validate(raw)
            load.assert_not_called()

    def test_token_limit(self):
        raw = ("apt: [" + ",".join("a" for _ in range(1500)) + "]").encode()
        self.assertLess(len(raw), MAX_BYTES)
        with patch("manifest.yaml.load") as load:
            with self.assertRaisesRegex(InvalidManifest, "^Invalid manifest$"):
                validate(raw)
            load.assert_not_called()


if __name__ == "__main__":
    unittest.main()
