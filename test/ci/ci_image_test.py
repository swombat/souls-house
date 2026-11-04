"""Toolchain drift is an error, not a silently stale browser cache."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def locked_package_version(lock, name):
    entry = re.search(r'"' + re.escape(name) + r'":\s*\["([^"]+)"', lock)
    if entry is None:
        return None
    specifier = entry.group(1)
    version = re.fullmatch(
        re.escape(name) + r'@(?:(\d+\.\d+\.\d+)|https://registry\.npmjs\.org/[^"]+-(\d+\.\d+\.\d+)\.tgz)',
        specifier,
    )
    return (version.group(1) or version.group(2)) if version else None


class CiImageTest(unittest.TestCase):
    def test_locked_package_version_accepts_both_bun_notations(self):
        for name in ("@playwright/test", "@playwright/experimental-ct-svelte"):
            tarball = name.rsplit("/", 1)[-1]
            for specifier in (
                f"{name}@1.55.0",
                f"{name}@https://registry.npmjs.org/{name}/-/{tarball}-1.55.0.tgz",
            ):
                with self.subTest(name=name, specifier=specifier):
                    lock = f'"{name}": ["{specifier}", "", {{}}, "sha512-example"],'
                    self.assertEqual("1.55.0", locked_package_version(lock, name))

    def test_locked_package_version_rejects_missing_or_unrecognized_entries(self):
        name = "@playwright/test"
        for lock in (
            '"@playwright/test-extra": ["@playwright/test-extra@1.55.0"],',
            '"@playwright/test": ["another-package@1.55.0"],',
            '"@playwright/test": ["@playwright/test@latest"],',
            '"@playwright/test": ["@playwright/test@1.55.0.tgz"],',
            '"@playwright/test": ["@playwright/test@https://registry.npmjs.org/@playwright/test/-/test-1.55.0"],',
        ):
            with self.subTest(lock=lock):
                self.assertIsNone(locked_package_version(lock, name))

    def test_locked_package_version_preserves_different_versions(self):
        lock = '"@playwright/test": ["@playwright/test@1.55.1", "", {}],'
        self.assertEqual("1.55.1", locked_package_version(lock, "@playwright/test"))
        self.assertNotEqual("1.55.0", locked_package_version(lock, "@playwright/test"))

    def test_ci_native_tools_use_production_debian_generation(self):
        dockerfile = (ROOT / ".github/ci/Dockerfile").read_text()
        for image in ("ruby:${RUBY_VERSION}-slim-trixie", "node:${NODE_VERSION}-trixie-slim"):
            self.assertRegex(dockerfile, re.escape("FROM " + image) + r"@sha256:[0-9a-f]{64}\b")
        workflow = (ROOT / ".github/workflows/ci-image.yml").read_text()
        self.assertIn('test "$(. /etc/os-release; echo "$VERSION_CODENAME")" = trixie', workflow)
        self.assertIn("getconf GNU_LIBC_VERSION", workflow)

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
            version = locked_package_version(lock, name)
            self.assertIsNotNone(version, f"Cannot find locked version of {name}")
            self.assertEqual(pins["PLAYWRIGHT_VERSION"], version)

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
        self.assertIn("bundle install --jobs 4 --retry 3", workflow)
        self.assertIn('bundle exec ruby -rbundler/setup -e "Bundler.require(:default)"', workflow)
        self.assertIn("--env BUNDLE_FROZEN=true", workflow)
        self.assertNotIn('source=$PWD,target=', workflow)

    def test_rails_runtime_tools_are_installed_and_smoked(self):
        dockerfile = (ROOT / ".github/ci/Dockerfile").read_text()
        workflow = (ROOT / ".github/workflows/ci-image.yml").read_text()
        for package in ("python3", "python3-yaml", "openssh-client", "util-linux"):
            self.assertRegex(dockerfile, r"\b" + re.escape(package) + r"\b")
        self.assertIn("import sys, yaml, tomllib", workflow)
        self.assertIn("sys.version_info >= (3, 11)", workflow)
        self.assertIn("python3 git ssh-keygen /usr/bin/script ffmpeg ffprobe sh date sleep", workflow)


if __name__ == "__main__":
    unittest.main()
