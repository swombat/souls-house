"""soulshouse-voice's list output, offline: no server, no credentials."""

import importlib.machinery
import importlib.util
from pathlib import Path
import unittest


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "soulshouse_voice", str(Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-voice")
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


voice = load_helper()
ARIA = {"voice_id": "std-aria", "name": "Aria", "labels": {"accent": "american"}}
JANIS = {"voice_id": "own-janis", "name": "Janis", "labels": {}, "description": "Cloned."}


class ListLinesTests(unittest.TestCase):
    def test_own_voices_are_their_own_group_with_the_current_one_marked(self):
        out, err = voice.list_lines({"voice_id": "own-janis", "voice": JANIS, "voices": [ARIA], "library_voices": [JANIS]})
        self.assertEqual([], err)
        self.assertIn("  std-aria  Aria: american", out)
        self.assertIn("Your account's own ElevenLabs voices:", out)
        self.assertIn("* own-janis  Janis: Cloned.", out)

    def test_a_current_voice_in_neither_readable_list_is_kept(self):
        out, _ = voice.list_lines({"voice_id": "legacy", "voice": None, "voices": [ARIA], "library_voices": []})
        self.assertIn("* legacy  (your current voice; not in either list, kept until you change it)", out)

    def test_a_library_outage_keeps_the_current_id_with_membership_unknown(self):
        out, err = voice.list_lines({"voice_id": "own-janis", "voice": None, "voices": [ARIA],
                                     "library_voices": [], "library_unavailable": "401"})
        self.assertIn("Your account's own voices can't be read just now: 401", err)
        self.assertTrue(any(line.startswith("* own-janis") and "unknown" in line for line in out))

    def test_a_standard_outage_keeps_the_current_id_too(self):
        out, err = voice.list_lines({"voice_id": "std-aria", "voice": None, "voices": [], "unavailable": "503"})
        self.assertEqual(["The voice list is unavailable just now: 503"], err)
        self.assertTrue(any(line.startswith("* std-aria") and "unknown" in line for line in out))

    def test_no_voice_says_so(self):
        out, _ = voice.list_lines({"voice_id": None, "voices": [ARIA]})
        self.assertEqual("You have no voice yet.", out[-1])


if __name__ == "__main__":
    unittest.main()
