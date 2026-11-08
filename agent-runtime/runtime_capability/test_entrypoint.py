"""Structural startup contract; not a candidate-image boot test."""

from pathlib import Path
import unittest


class EntrypointTests(unittest.TestCase):
    def test_receipt_directory_setup_is_independent_of_service_manifest(self):
        path = Path(__file__).resolve().parent.parent / "entrypoint.sh"
        if not path.exists():
            path = Path("/usr/local/bin/entrypoint.sh")  # Candidate image layout.
        source = path.read_text()
        setup = (
            "mkdir -p /run/helixkit\n"
            "chown 1000:1000 /run/helixkit\n"
            "chmod 0700 /run/helixkit\n"
        )
        self.assertEqual(source.count(setup), 1)
        self.assertLess(source.index(setup),
                        source.index("if [ -f /run/helixkit-source.yml ]; then"))
