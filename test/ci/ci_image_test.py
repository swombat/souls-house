"""Toolchain drift is an error, not a silently stale browser cache."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CiImageTest(unittest.TestCase):
    def test_ruby_pins_match_local_development(self):
        version = (ROOT / ".ruby-version").read_text().strip()
        self.assertRegex((ROOT / "mise.toml").read_text(), rf'(?m)^ruby = "{re.escape(version)}"$')
        for path in ("Dockerfile", ".github/ci/Dockerfile"):
            self.assertIn(f"ARG RUBY_VERSION={version}\n", (ROOT / path).read_text())
        for path in ("agent-runtime/Dockerfile.mira-dev", "ops/deploy/Dockerfile"):
            self.assertIn(f"FROM ruby:{version}-slim-trixie", (ROOT / path).read_text())

    def test_image_matches_application_pins(self):
        dockerfile = (ROOT / ".github/ci/Dockerfile").read_text()
        pins = dict(re.findall(r"^ARG (\w+)=([^\n]+)$", dockerfile, re.M))
        self.assertEqual(pins["RUBY_VERSION"], (ROOT / ".ruby-version").read_text().strip())
        package = json.loads((ROOT / "package.json").read_text())
        self.assertEqual(pins["BUN_VERSION"], package["packageManager"].removeprefix("bun@"))
        lock = (ROOT / "bun.lock").read_text()
        for name in ("@playwright/test", "@playwright/experimental-ct-svelte"):
            version = re.search(r'"' + re.escape(name) + r'": \["[^"]+-(\d+\.\d+\.\d+)\.tgz"', lock)
            self.assertIsNotNone(version, f"Cannot find locked version of {name}")
            self.assertEqual(pins["PLAYWRIGHT_VERSION"], version.group(1))

    def test_image_context_contains_no_application_or_credentials(self):
        context = ROOT / ".github/ci"
        self.assertEqual({"Dockerfile"}, {p.name for p in context.iterdir()})
        dockerfile = (context / "Dockerfile").read_text()
        copies = [line for line in dockerfile.splitlines() if line.startswith("COPY ")]
        self.assertTrue(copies)
        self.assertTrue(all(line.startswith("COPY --from=") for line in copies))

    def test_native_gem_validation_uses_only_readonly_manifests(self):
        workflow = (ROOT / ".github/workflows/ci-image.yml").read_text()
        for manifest in ("Gemfile", "Gemfile.lock", ".ruby-version"):
            self.assertIn(f"source=$PWD/{manifest},target=/check/{manifest},readonly", workflow)
        self.assertIn("ci-tooling:check bundle install --jobs 4 --retry 3", workflow)
        self.assertIn("--env BUNDLE_FROZEN=true", workflow)
        self.assertNotIn('source=$PWD,target=', workflow)

    def test_rails_runtime_tools_are_installed_and_smoked(self):
        dockerfile = (ROOT / ".github/ci/Dockerfile").read_text()
        workflow = (ROOT / ".github/workflows/ci-image.yml").read_text()
        for package in ("python3", "python3-yaml", "openssh-client", "util-linux"):
            self.assertRegex(dockerfile, r"\b" + re.escape(package) + r"\b")
        self.assertIn("import sys, yaml, tomllib", workflow)
        self.assertIn("sys.version_info >= (3, 11)", workflow)
        self.assertIn("python3 git ssh-keygen /usr/bin/script ffmpeg ffprobe pdfinfo pdftotext pdftoppm sh date sleep", workflow)


if __name__ == "__main__":
    unittest.main()
