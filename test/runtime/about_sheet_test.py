import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / "agent-runtime"
sys.path.insert(0, str(RUNTIME))
import about_sheet

SHEET = "# About souls.house\n\nAs of 2026-10-25, house version 0.1.0 abc1234.\n"
NOW = 2_000_000_000


class AboutSheetDeliveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.live = root / "cache" / "about-souls-house.md"
        self.docs = root / "docs"
        self.docs.mkdir()
        env = patch.dict(os.environ, {
            "SOULSHOUSE_ABOUT_SHEET_PATH": str(self.live),
            "AGENT_RUNTIME_DOCS_PATH": str(self.docs),
            "SOULSHOUSE_APP_URL": "https://house.example/",
            "SOULSHOUSE_BEARER_TOKEN": "resident-token",
        })
        env.start()
        self.addCleanup(env.stop)

    def age(self, seconds):
        os.utime(self.live, (NOW - seconds, NOW - seconds))

    def test_fetch_success_writes_the_sheet(self):
        calls = []
        status = about_sheet.refresh(fetch=lambda url, token: calls.append((url, token)) or SHEET.encode(), now=NOW)
        self.assertEqual(status, "fetched")
        self.assertEqual(calls, [("https://house.example/api/v1/about_house", "resident-token")])
        self.assertEqual(self.live.read_text(), SHEET)
        note = about_sheet.hosting_note(status, now=NOW + 5)
        self.assertIn(str(self.live), note)
        self.assertIn("generated from the release it is running", note)
        self.assertIn("account's owner", note)
        self.assertIn("/features", note)
        # A mention, not an instruction (Daniel, jbaRZe): residents aren't told how to answer.
        for imperative in ("Answer questions", "Say that", "say you don't know"):
            self.assertNotIn(imperative, note)

    def test_fetch_failure_keeps_the_last_good_copy_and_says_its_age(self):
        self.live.parent.mkdir(parents=True)
        self.live.write_text(SHEET)
        self.age(3 * 86400)

        def boom(url, token):
            raise OSError("house unreachable")

        status = about_sheet.refresh(fetch=boom, now=NOW)
        self.assertTrue(status.startswith("failed"))
        self.assertEqual(self.live.read_text(), SHEET)
        note = about_sheet.hosting_note(status, now=NOW)
        self.assertIn("could not be reached", note)
        self.assertIn("3 days old", note)

    def test_a_reply_that_is_not_a_sheet_is_not_written(self):
        self.live.parent.mkdir(parents=True)
        self.live.write_text(SHEET)
        self.age(3600)
        status = about_sheet.refresh(fetch=lambda url, token: b"<html>login</html>", now=NOW)
        self.assertEqual(status, "failed: not a sheet")
        self.assertEqual(self.live.read_text(), SHEET)

    def test_a_recent_copy_is_not_fetched_again(self):
        self.live.parent.mkdir(parents=True)
        self.live.write_text(SHEET)
        self.age(60)
        status = about_sheet.refresh(fetch=lambda url, token: self.fail("fetched again"), now=NOW)
        self.assertEqual(status, "fresh")

    def test_absent_copy_falls_back_to_the_baked_one(self):
        (self.docs / "about-souls-house.md").write_text(SHEET)
        with patch.dict(os.environ, {"SOULSHOUSE_BEARER_TOKEN": ""}):
            status = about_sheet.refresh(now=NOW)
        self.assertTrue(status.startswith("failed"))
        self.assertFalse(self.live.exists())
        note = about_sheet.hosting_note(status, now=NOW)
        self.assertIn(str(self.docs / "about-souls-house.md"), note)
        self.assertIn("built into this runtime image", note)

    def test_no_copy_at_all_says_so_and_points_elsewhere(self):
        note = about_sheet.hosting_note("failed: OSError", now=NOW)
        self.assertIn("No sheet about souls.house is available", note)
        self.assertIn("account's owner", note)

    def test_the_image_ships_the_baked_copy(self):
        dockerfile = (RUNTIME / "Dockerfile").read_text()
        self.assertIn("COPY docs/about-souls-house.md /usr/local/share/helixkit-agent/about-souls-house.md", dockerfile)
        self.assertIn("about_sheet.py", dockerfile)
        self.assertTrue((RUNTIME / "docs" / "about-souls-house.md").read_text().startswith(about_sheet.HEADING))


class FreshSessionPromptTest(unittest.TestCase):
    def test_a_fresh_prompt_carries_the_note_after_identity(self):
        import importlib.util
        os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
        spec = importlib.util.spec_from_file_location("about_shim", RUNTIME / "trigger_shim.py")
        shim = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = shim
        spec.loader.exec_module(shim)
        with patch.dict(os.environ, {"SOULSHOUSE_HOME_PROFILE": "house"}), \
                patch.object(shim, "identity_context", return_value="STOCK"), \
                patch.object(shim, "memory_context", return_value=""), \
                patch.object(shim, "memory_command_reference", return_value=""), \
                patch.object(shim.about_sheet, "session_note", return_value="## About souls.house\nNOTE"):
            prompt, info = shim.build_prompt_with_components("REQUEST")
        self.assertTrue(prompt.startswith("STOCK\n\n## About souls.house\nNOTE\n\nREQUEST"))
        self.assertGreater(info["about_house"], 0)

    def test_an_imported_home_gets_the_note_without_house_journals(self):
        import importlib.util
        os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
        spec = importlib.util.spec_from_file_location("about_shim3", RUNTIME / "trigger_shim.py")
        shim = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = shim
        spec.loader.exec_module(shim)
        with patch.object(shim.imported_home, "enabled", return_value=True), \
                patch.object(shim.imported_home, "validate") as validate, \
                patch.object(shim, "imported_runtime_context", return_value="HOME CONTEXT"), \
                patch.object(shim, "identity_context", side_effect=AssertionError("stock identity")), \
                patch.object(shim, "memory_context", side_effect=AssertionError("house journals read")), \
                patch.object(shim.about_sheet, "session_note", return_value="## About souls.house\nNOTE"):
            prompt, info = shim.build_prompt_with_components("REQUEST")
        validate.assert_called_once()
        self.assertTrue(prompt.startswith("HOME CONTEXT\n\n## About souls.house\nNOTE\n\nREQUEST"))
        self.assertEqual(info["journal"], 0)
        self.assertGreater(info["about_house"], 0)

    def test_a_broken_sheet_never_breaks_the_prompt(self):
        import importlib.util
        os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
        spec = importlib.util.spec_from_file_location("about_shim2", RUNTIME / "trigger_shim.py")
        shim = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = shim
        spec.loader.exec_module(shim)
        with patch.object(shim.about_sheet, "session_note", side_effect=RuntimeError("boom")):
            self.assertEqual(shim.about_house_note(), "")


if __name__ == "__main__":
    unittest.main()
