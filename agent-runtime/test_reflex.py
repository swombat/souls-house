"""soulshouse-reflex paging: no credentials, server or network."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader("reflex_cli", str(Path(__file__).with_name("soulshouse-reflex")))
spec = importlib.util.spec_from_loader(loader.name, loader)
reflex = importlib.util.module_from_spec(spec)
loader.exec_module(reflex)


class ReflexTests(unittest.TestCase):
    def test_judgments_path_carries_the_cursor(self):
        self.assertEqual("/api/v1/reflexes/abc/judgments", reflex.judgments_path("abc"))
        self.assertEqual("/api/v1/reflexes/abc/judgments?cursor=XyZ", reflex.judgments_path("abc", "XyZ"))

    def test_ids_cannot_escape_the_endpoint(self):
        self.assertEqual("/api/v1/reflexes/..%2Fagents/judgments", reflex.judgments_path("../agents"))

    def test_all_follows_every_page(self):
        pages = {
            "/api/v1/reflexes/r/judgments": {"judgments": [{"id": "3"}, {"id": "2"}], "next_cursor": "2"},
            "/api/v1/reflexes/r/judgments?cursor=2": {"judgments": [{"id": "1"}], "next_cursor": None},
        }
        seen = []

        def fetch(path):
            seen.append(path)
            return pages[path]

        result = reflex.all_judgments(fetch, "r")
        self.assertEqual(["3", "2", "1"], [j["id"] for j in result["judgments"]])
        self.assertEqual(list(pages), seen)


if __name__ == "__main__":
    unittest.main()
