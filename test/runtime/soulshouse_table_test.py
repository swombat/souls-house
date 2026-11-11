"""soulshouse-table, offline: a fake client records the requests. In runtime CI discovery."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader("table_cli", str(Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-table"))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)


class FakeClient:
    def __init__(self, tables=None, rows=None):
        self.calls = []
        self.tables = tables or [{"id": "abcDEF", "name": "Build in public posts"}]
        self.rows = rows

    def call(self, method, path, payload=None, query=None):
        self.calls.append((method, path, payload, query))
        if method == "GET" and path == "/api/v1/field_tables":
            return {"field_tables": self.tables}
        if method == "GET" and path.endswith("/rows"):
            return self.rows or {"rows": [], "columns": []}
        return {"ok": True}


def run(argv, client):
    return cli.run(cli.parser().parse_args(argv), client)


class TableTests(unittest.TestCase):
    def test_a_table_is_found_by_exact_name_case_insensitively(self):
        client = FakeClient()
        run(["add", "build in PUBLIC posts", "platform=x", "views=3"], client)
        self.assertEqual(("POST", "/api/v1/field_tables/abcDEF/rows", {"data": {"platform": "x", "views": "3"}}, None),
                         client.calls[-1])

    def test_an_unknown_name_is_treated_as_an_id_and_ids_cannot_escape_the_endpoint(self):
        client = FakeClient()
        run(["show", "XyZ123"], client)
        self.assertEqual(("GET", "/api/v1/field_tables/XyZ123", None, None), client.calls[-1])
        with self.assertRaises(cli.Failure):
            run(["show", "../agents"], FakeClient())

    def test_create_declares_typed_columns(self):
        client = FakeClient()
        run(["create", "Posts", "--column", "date:date", "--column", "platform", "--column", "link:link:The link"], client)
        self.assertEqual({"name": "Posts", "columns": [{"key": "date", "type": "date"}, {"key": "platform"},
                                                        {"key": "link", "type": "link", "label": "The link"}]},
                         client.calls[-1][2])

    def test_update_sends_lock_version_and_empty_clears(self):
        client = FakeClient()
        run(["update", "abcDEF", "RoW1", "title=", "views=4", "--lock-version", "2"], client)
        self.assertEqual(("PATCH", "/api/v1/field_tables/abcDEF/rows/RoW1",
                          {"data": {"title": None, "views": "4"}, "lock_version": 2}, None), client.calls[-1])

    def test_read_passes_where_and_sort(self):
        client = FakeClient()
        run(["read", "abcDEF", "--where", "platform=x", "--sort", "date", "--desc", "--limit", "5"], client)
        self.assertEqual([("where[platform]", "x"), ("sort", "-date"), ("limit", 5)], client.calls[-1][3])

    def test_column_change_maps_new_key_and_refuses_odd_keys(self):
        client = FakeClient()
        run(["columns", "abcDEF", "change", "views", "--new-key", "reach"], client)
        self.assertEqual(("PATCH", "/api/v1/field_tables/abcDEF/columns/views", {"new_key": "reach"}, None), client.calls[-1])
        with self.assertRaises(cli.Failure):
            run(["columns", "abcDEF", "remove", "../x"], FakeClient())

    def test_export_writes_csv_in_column_order(self):
        rows = {"columns": [{"key": "a"}, {"key": "b"}], "rows": [{"data": {"b": 2, "a": "x"}}, {"data": {"a": "y"}}]}
        self.assertEqual("a,b\r\nx,2\r\ny,\r\n", cli.to_csv(rows["columns"], rows["rows"]))


if __name__ == "__main__":
    unittest.main()
