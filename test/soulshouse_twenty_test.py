"""Offline contract/security tests; no provider requests or inherited credentials."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse

import yaml

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("twenty", str(ROOT / "agent-runtime/soulshouse-twenty"))
spec = importlib.util.spec_from_loader(loader.name, loader)
twenty = importlib.util.module_from_spec(spec)
loader.exec_module(twenty)
ID = "bcb318a7-c7f0-45a5-a7f8-633265463e46"
KEY = "synthetic-only-key"


class TwentyTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "services.yml"
        self.environment = patch.dict(os.environ, {"SOULSHOUSE_SERVICES_FILE": str(self.path)}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.service = {"provider": "twenty", "connection_id": "svc_test",
                        "credentials": {"api_key": KEY},
                        "metadata": {"api_base": "https://crm.example.test/rest"}}
        self.manifest([self.service])
        self.page = {"data": {"people": [{"id": ID}]}, "pageInfo": {
            "hasNextPage": True, "hasPreviousPage": False, "startCursor": "start", "endCursor": "end"}}
        self.open = patch.object(twenty.OPENER, "open").start()
        self.addCleanup(patch.stopall)
        self.respond(self.page)

    def manifest(self, services):
        self.path.write_text(yaml.safe_dump({"services": services}))

    def respond(self, value):
        self.open.return_value.__enter__.return_value.read.return_value = json.dumps(value).encode()

    def invoke(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = twenty.main(list(args))
            except SystemExit as error:
                code = error.code
        return code, out.getvalue(), err.getvalue()

    def test_list_is_one_get_page_with_cursor(self):
        code, out, err = self.invoke("people", "--limit", "1", "--after", "a+/=")
        self.assertEqual(0, code, err)
        self.assertEqual(self.page, json.loads(out))
        self.open.assert_called_once()
        request = self.open.call_args.args[0]
        self.assertEqual("GET", request.method)
        self.assertEqual("Bearer " + KEY, request.get_header("Authorization"))
        self.assertEqual({"limit": ["1"], "depth": ["0"], "starting_after": ["a+/="]},
                         urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query))
        self.assertNotIn(KEY, request.full_url)
        self.assertEqual(30, self.open.call_args.kwargs["timeout"])

    def test_search_filters_and_other_objects(self):
        for obj in ("people", "companies"):
            self.respond({**self.page, "data": {obj: []}})
            code, _, err = self.invoke(obj, "--search", "Ada Lovelace")
            self.assertEqual(0, code, err)
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.open.call_args.args[0].full_url).query)
            self.assertIn('[ilike]:"%Ada Lovelace%"', query["filter"][0])
            if obj == "people":
                self.assertIn("name.firstName", query["filter"][0])
                self.assertIn("name.lastName", query["filter"][0])
        self.respond({**self.page, "data": {"opportunities": []}})
        self.assertEqual(0, self.invoke("opportunities")[0])
        self.assertNotEqual(0, self.invoke("opportunities", "--search", "x")[0])

    def test_get_and_connection_before_or_after(self):
        self.manifest([self.service, {**self.service, "connection_id": "svc_other"}])
        self.assertNotEqual(0, self.invoke("people")[0])
        self.open.assert_not_called()
        self.respond({"data": {"person": {"id": ID}}})
        for args in (("--connection", "svc_other", "get", "people", ID),
                     ("get", "people", ID, "--connection", "svc_test")):
            self.assertEqual(0, self.invoke(*args)[0])
            self.assertTrue(self.open.call_args.args[0].full_url.endswith("/people/" + ID + "?depth=0"))
        for obj, singular in twenty.OBJECTS.items():
            self.respond({"data": {singular: {"id": ID}}})
            self.assertEqual(0, self.invoke("get", obj, ID, "--connection", "svc_test")[0])
            self.assertTrue(self.open.call_args.args[0].full_url.endswith(
                f"/{obj}/{ID}?depth=0"))

    def test_safe_subdirectory_instance_paths(self):
        for prefix in ("", "/crm", "/crm/team_2-prod"):
            self.manifest([{**self.service, "metadata": {
                "api_base": "https://crm.example.test" + prefix + "/rest"}}])
            self.respond(self.page)
            self.assertEqual(0, self.invoke("people")[0])
            self.assertEqual(prefix + "/rest/people",
                             urllib.parse.urlsplit(self.open.call_args.args[0].full_url).path)
            self.respond({"data": {"person": {"id": ID}}})
            self.assertEqual(0, self.invoke("get", "people", ID)[0])
            url = urllib.parse.urlsplit(self.open.call_args.args[0].full_url)
            self.assertEqual(prefix + "/rest/people/" + ID, url.path)
            self.assertEqual({"depth": ["0"]}, urllib.parse.parse_qs(url.query))

    def test_invalid_arguments_never_connect(self):
        for args in (("people", "--limit", "0"), ("people", "--limit", "101"),
                     ("people", "--limit", "wat"), ("people", "--after", "\n"),
                     ("people", "--search", 'x"),not(id[is]:NULL)'),
                     ("people", "--search", "%"), ("get", "people", "../x"),
                     ("get", "evil", ID), ("delete", "people", ID)):
            self.assertNotEqual(0, self.invoke(*args)[0])
        self.open.assert_not_called()

    def test_bad_manifest_shapes_and_yaml_are_safe(self):
        for text in ("[secret]", "services: secret", "services: [null]",
                     "services: [", "services: []", "!!python/object:secret {}"):
            self.path.write_text(text)
            code, out, err = self.invoke("people")
            self.assertEqual(1, code)
            self.assertNotIn("secret", out + err)
        for field in ("metadata", "credentials"):
            self.manifest([{**self.service, field: ["secret"]}])
            self.assertEqual(1, self.invoke("people")[0])
        self.open.assert_not_called()

    def test_invalid_keys_and_urls_never_connect_or_leak(self):
        for key in ("", None, [], "secret\ninjection", "secret\t", "secret\x7f", "secret é"):
            self.manifest([{**self.service, "credentials": {"api_key": key}}])
            code, out, err = self.invoke("people")
            self.assertEqual(1, code)
            self.assertNotIn("secret", out + err)
        for base in ("http://crm.test/rest", "https://secret@crm.test/rest",
                     "https://crm.test/rest?secret", "https://crm.test/rest#secret",
                     "https://crm.test/rest?", "https://crm.test/rest#",
                     "https://crm.test:bad/rest", "https://[bad/rest", None, [],
                     "https://crm.test/\nrest", "https://crm.test/other",
                     "https://crm.test/crm/../rest", "https://crm.test/crm%2frest",
                     "https://crm.test//rest", "https://crm.test/crm.example/rest",
                     "https://crm.test/crm;/rest", "https://crm.test/crm\\rest"):
            self.manifest([{**self.service, "metadata": {"api_base": base}}])
            code, out, err = self.invoke("people")
            self.assertEqual(1, code)
            self.assertNotIn("secret", out + err)
        self.open.assert_not_called()

    def test_errors_do_not_include_bodies_keys_or_urls(self):
        for error in (urllib.error.HTTPError("https://secret", 401, KEY, {}, io.BytesIO(KEY.encode())),
                      urllib.error.URLError(KEY), TimeoutError(KEY), OSError(KEY)):
            self.open.side_effect = error
            code, out, err = self.invoke("people")
            self.assertEqual(1, code)
            self.assertNotIn(KEY, out + err)
            self.assertNotIn("https://secret", out + err)

    def test_bad_json_and_shapes(self):
        for value in ([], None, {}, {"data": []}, {"data": {"people": {}}},
                      {"data": {"people": [None]}, "pageInfo": {}},
                      {"data": {"people": []}, "pageInfo": {"hasNextPage": "yes"}}):
            self.respond(value)
            self.assertEqual(1, self.invoke("people")[0])
        for raw in (b"not json " + KEY.encode(), b"\xff", b"[" * 2000):
            self.open.return_value.__enter__.return_value.read.return_value = raw
            code, out, err = self.invoke("people")
            self.assertEqual(1, code)
            self.assertNotIn(KEY, out + err)
        self.respond({"data": {"person": []}})
        self.assertEqual(1, self.invoke("get", "people", ID)[0])

    def test_redirect_handler_refuses_without_disclosing_location(self):
        for status in (301, 302, 303, 307, 308):
            with self.assertRaises(twenty.TwentyError) as caught:
                twenty.RefuseRedirects().redirect_request(None, None, status, "", {},
                                                         "https://secret.test/" + KEY)
            self.assertNotIn(KEY, str(caught.exception))
            self.assertNotIn("secret.test", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
