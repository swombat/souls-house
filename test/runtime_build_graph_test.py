"""Source/build ordering contract; no Docker daemon or resident state required."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeBuildGraphTest(unittest.TestCase):
    def test_default_build_downloads_pinned_binaries_without_compiling(self):
        dockerfile = (ROOT / "agent-runtime/Dockerfile").read_text()
        self.assertIn("ARG CHAOS_BUILD_MODE=prebuilt", dockerfile)
        self.assertIn("FROM chaos-${CHAOS_BUILD_MODE} AS builder", dockerfile)
        prebuilt = dockerfile.split("AS chaos-prebuilt", 1)[1].split("FROM chaos-${", 1)[0]
        self.assertNotIn("cargo", prebuilt)
        self.assertNotIn("git clone", prebuilt)
        self.assertIn('"${CHAOS_HEAD}" "${TARGETARCH}"', prebuilt)
        for binary in ("chaos", "chaos_journald"):
            self.assertIn(f"COPY --from=builder /usr/local/bin/{binary} /usr/local/bin/{binary}", dockerfile)

    def test_final_source_is_built_once_for_both_runtime_binaries(self):
        dockerfile = (ROOT / "agent-runtime/Dockerfile").read_text()
        builder = dockerfile.split("FROM oven/bun:", 1)[0]
        self.assertNotIn("git apply", builder, "use accepted upstream source, not local patches")
        self.assertNotIn("COPY patches/", builder)
        self.assertIn('LABEL house.souls.chaos-patches=""', dockerfile)
        self.assertFalse(list((ROOT / "agent-runtime/patches").glob("*.patch")))
        commands = re.sub(r"\\\s*\n\s*", " ", builder)
        builds = list(re.finditer(r"\bcargo build\b[^\n]*", commands))
        self.assertEqual(len(builds), 1, "do not append patch-and-rebuild layers")
        self.assertIn("--bin chaos ", builds[0].group())
        self.assertIn("--bin chaos_journald", builds[0].group())
        for mutation in re.finditer(r"\bgit (?:apply|checkout)\b", commands):
            self.assertLess(mutation.start(), builds[0].start())
        gate = commands.index("cargo test --release")
        self.assertLess(gate, builds[0].start())
        self.assertIn("-p chaos-clamp --lib", commands[gate:builds[0].start()])
        for mutation in re.finditer(r"\bgit (?:apply|checkout)\b", commands):
            self.assertLess(mutation.start(), gate)


if __name__ == "__main__":
    unittest.main()
