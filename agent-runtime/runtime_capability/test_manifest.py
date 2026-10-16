import unittest

from manifest import InvalidManifest, MAX_BYTES, validate


class ManifestTests(unittest.TestCase):
    def test_reviewed_and_unsupported(self):
        result = validate(b"""
apt:
  - {name: ffmpeg, reason: Decode audio}
pip:
  - {name: numpy, reason: Measure}
  - {name: scipy, reason: Analyse}
  - {name: other, reason: Future work}
""")
        self.assertEqual([d.supported for d in result], [True, True, True, False])
        self.assertNotIn("Decode audio", repr(result))

    def test_multiline_reason_removed(self):
        result = validate(b"pip:\n  - name: numpy\n    reason: |\n      PRIVATE\n      citation\n")
        self.assertNotIn("PRIVATE", repr(result))

    def test_invalid_cases_are_generic(self):
        cases = [
            b"", b"null", b"[]", b"\xff", b"x" * (MAX_BYTES + 1),
            b"apt: [", b"apt: !!python/object:private {}",
            b"apt: []\napt: []", b"apt: &a []\npip: *a",
            b"pip: [{name: numpy, name: scipy, reason: PRIVATE}]",
            b"pip: [{name: numpy, reason: PRIVATE}, {name: numpy, reason: PRIVATE}]",
            b"pip: [{name: numpy, reason: true}]",
            b"pip: [{name: '$(PRIVATE)', reason: PRIVATE}]",
            b"pip: [{name: numpy, reason: PRIVATE, command: PRIVATE}]",
            b"pip: [{name: numpy}]", b"apt: {}", b"other: []",
            ("pip:\n" + "".join(
                f"  - {{name: package{i}, reason: PRIVATE}}\n" for i in range(33)
            )).encode(),
        ]
        for raw in cases:
            with self.subTest(raw=raw[:80]):
                with self.assertRaises(InvalidManifest) as caught:
                    validate(raw)
                self.assertEqual(str(caught.exception), "Invalid manifest")

    def test_explicit_empty_lists_valid(self):
        self.assertEqual(validate(b"apt: []\npip: []"), ())

    def test_pip_names_normalized_before_review_and_duplicate_check(self):
        result = validate(b"pip: [{name: NumPy, reason: PRIVATE}, {name: PyYAML, reason: PRIVATE}, {name: Some_Package.name, reason: PRIVATE}]")
        self.assertEqual([d.name for d in result], ["numpy", "pyyaml", "some-package-name"])
        self.assertEqual([d.supported for d in result], [True, False, False])
        for names in [("NumPy", "numpy"), ("some_package", "some-package")]:
            raw = f"pip: [{{name: {names[0]}, reason: PRIVATE}}, {{name: {names[1]}, reason: PRIVATE}}]".encode()
            with self.assertRaises(InvalidManifest):
                validate(raw)

    def test_names_must_start_with_ascii_alphanumeric(self):
        for channel in ("apt", "pip"):
            for name in ("-e", "..", "_name", "+name"):
                with self.subTest(channel=channel, name=name):
                    with self.assertRaises(InvalidManifest):
                        validate(f"{channel}: [{{name: '{name}', reason: PRIVATE}}]".encode())
        with self.assertRaises(InvalidManifest):
            validate(b"apt: [{name: FFmpeg, reason: PRIVATE}]")


if __name__ == "__main__":
    unittest.main()
