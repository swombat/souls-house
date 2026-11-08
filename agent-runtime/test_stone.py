"""Pure request construction tests: no credentials, server or network."""
import argparse
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest

loader = importlib.machinery.SourceFileLoader("stone_cli", str(Path(__file__).with_name("soulshouse-stone")))
spec = importlib.util.spec_from_loader(loader.name, loader)
stone = importlib.util.module_from_spec(spec)
loader.exec_module(stone)


class StoneTests(unittest.TestCase):
    def test_public_acknowledgement_is_required(self):
        with self.assertRaises(SystemExit):
            stone.parser().parse_args(["create", "--conversation", "abc", "--title", "Example", "--file", "page.html"])

    def test_revision_request_preserves_literal_html_and_base(self):
        with tempfile.NamedTemporaryFile(suffix=".html") as file:
            file.write(b"<!doctype html><h1>$100 `literal`</h1>")
            file.flush()
            args = stone.parser().parse_args([
                "revise", "--conversation", "chat", "--stone", "stone",
                "--title", "Options", "--file", file.name, "--public",
                "--base-revision", "revision",
            ])
            method, path, payload = stone.request_spec(args)
        self.assertEqual("POST", method)
        self.assertEqual("/api/v1/conversations/chat/stones/stone/revisions", path)
        self.assertEqual("<!doctype html><h1>$100 `literal`</h1>", payload["html"])
        self.assertTrue(payload["public"])
        self.assertNotIn("interactive", payload)
        self.assertEqual("revision", payload["base_revision_id"])

    def test_interactive_requires_explicit_cli_flag(self):
        with tempfile.NamedTemporaryFile(suffix=".html") as file:
            file.write(b"<!doctype html><script>1</script>")
            file.flush()
            args = stone.parser().parse_args([
                "create", "--conversation", "chat", "--title", "Sound",
                "--file", file.name, "--public", "--interactive",
            ])
            _, _, payload = stone.request_spec(args)
        self.assertIs(True, payload["interactive"])

    def test_ids_cannot_escape_the_endpoint(self):
        with self.assertRaises(ValueError):
            stone.request_spec(argparse.Namespace(operation="list", conversation="../agents"))

    def test_redirects_never_forward_the_resident_token(self):
        self.assertIsNone(stone.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example"))


if __name__ == "__main__":
    unittest.main()
