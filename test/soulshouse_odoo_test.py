import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import ssl
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "agent-runtime/soulshouse-odoo"
loader = importlib.machinery.SourceFileLoader("odoo_helper", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
odoo = importlib.util.module_from_spec(spec)
loader.exec_module(odoo)
KEY = "synthetic-secret-key"
META = {"api_url": "https://odoo.example/jsonrpc", "database": "test",
        "login": "reader", "uid": 7, "protocol": "jsonrpc", "odoo_version": "18.0.0",
        "edition": "not checked", "accounting_modules": "not checked"}


class OdooTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "services.yml"
        self.env = patch.dict(os.environ, {"SOULSHOUSE_SERVICES_FILE": str(self.path)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.write()
        # Any accidental unmocked network use fails rather than reaching live services.
        self.network = patch.object(socket, "socket", side_effect=AssertionError("live network"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def write(self, **meta):
        data = dict(META, **meta)
        self.service = {"provider": "odoo", "connection_id": "svc_test",
                        "credentials": {"api_key": KEY}, "metadata": data}
        self.path.write_text(json.dumps({"services": [self.service]}))

    def invoke(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = odoo.main(list(args))
        self.assertNotIn(KEY, out.getvalue() + err.getvalue())
        return status, out.getvalue(), err.getvalue()

    def test_manifest_json_yaml_and_selection(self):
        self.assertEqual((META, KEY), odoo.load_connection(None))
        lines = ["---", "services:", "- provider: odoo", "  connection_id: svc_test",
                 "  credentials:", f"    api_key: {KEY}", "  metadata:"]
        lines += [f"    {k}: {v}" for k, v in META.items()]
        lines += ["- provider: ghost", "  connection_id: svc_blog",
                  "  credentials:", "    admin_api_key: 'other:key'",
                  "  metadata:", "    tags: []", "    enabled: true"]
        self.path.write_text("\n".join(lines))
        self.assertEqual((META, KEY), odoo.load_connection("svc_test"))
        with self.assertRaises(odoo.OdooError):
            odoo.load_connection("missing")
        self.path.write_text(json.dumps({"services": [self.service, self.service]}))
        with self.assertRaises(odoo.OdooError):
            odoo.load_connection(None)

    def test_metadata_rejected_before_network(self):
        for field, values in {"protocol": ["xmlrpc", "json2", None],
                              "odoo_version": ["15.0", "20.0", "saas~15.9", "saas~20.0",
                                               "saas~", "saas~~19.4", "SaaS~19.4",
                                               "xsaas~19.4", "saas~19.", "19.0junk",
                                               "19.0+community", "", 19, True, None, []],
                              "uid": [False, 0, "7"], "database": ["", None],
                              "login": ["", None]}.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    self.write(**{field: value})
                    self.assertEqual(1, self.invoke("partners")[0])
        for version in ("16.0", "17.0", "18.0+e", "19.0.0", "saas~16.0",
                        "saas~17.0", "saas~18", "saas~19.4.0", "saas~19.4+e"):
            with self.subTest(version=version):
                self.write(odoo_version=version)
                self.assertEqual(version, odoo.load_connection(None)[0]["odoo_version"])

    def test_fixed_read_operations(self):
        for command, model in (("partners", "res.partner"), ("invoices", "account.move")):
            with patch.object(odoo, "Client") as client:
                client.return_value.call.side_effect = [7, [{"id": 1}]]
                status, out, err = self.invoke(command, "--connection", "svc_test",
                                               "--limit", "3", "--offset", "2")
                self.assertEqual((0, ""), (status, err))
                self.assertEqual([{"id": 1}], json.loads(out))
                calls = client.return_value.call.call_args_list
                self.assertEqual(("common", "authenticate", ["test", "reader", KEY, {}]), calls[0].args)
                service, method, args = calls[1].args
                self.assertEqual(("object", "execute_kw"), (service, method))
                self.assertEqual(["test", 7, KEY, model, "search_read"], args[:5])
                self.assertEqual({"limit": 3, "offset": 2, "order": "id asc"},
                                 {k: args[6][k] for k in ("limit", "offset", "order")})
                if command == "invoices":
                    self.assertEqual([[["move_type", "in", ["out_invoice", "in_invoice"]]]], args[5])
                    self.assertIn("payment_state", args[6]["fields"])

    def test_saas_19_partners_read_only(self):
        self.write(odoo_version="saas~19.4.0")
        with patch.object(odoo, "Client") as client:
            client.return_value.call.side_effect = [7, [{"id": 1, "name": "Example"}]]
            status, out, err = self.invoke("partners")
            self.assertEqual((0, ""), (status, err))
            self.assertEqual([{"id": 1, "name": "Example"}], json.loads(out))
            self.assertEqual([
                unittest.mock.call("common", "authenticate", ["test", "reader", KEY, {}]),
                unittest.mock.call("object", "execute_kw", [
                    "test", 7, KEY, "res.partner", "search_read", [[]],
                    {"fields": ["id", "name", "email", "phone", "is_company"],
                     "limit": 20, "offset": 0, "order": "id asc"}]),
            ], client.return_value.call.call_args_list)

    def test_bounds_uid_and_credential_echo(self):
        for option, value in (("--limit", "0"), ("--limit", "101"),
                              ("--offset", "-1"), ("--offset", "100001")):
            with patch.object(odoo, "Client") as client:
                self.assertEqual(1, self.invoke("partners", option, value)[0])
                client.assert_not_called()
        for results in ([8], [False], [7, [{"name": KEY}]], [7, {"error": KEY}]):
            with patch.object(odoo, "Client") as client:
                client.return_value.call.side_effect = results
                self.assertEqual(1, self.invoke("partners")[0])

    def test_arbitrary_commands_not_exposed(self):
        for command in ("write", "create", "execute_kw", "unlink"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                odoo.build_parser().parse_args([command])
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            odoo.main(["partners", "--unknown", KEY])
        self.assertNotIn(KEY, err.getvalue())

    def address(self, ip):
        return (socket.AF_INET6 if ":" in ip else socket.AF_INET,
                socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (ip, 443))

    def test_rejects_non_global_and_mixed_dns(self):
        for ip in ("127.0.0.1", "10.1.2.3", "169.254.169.254", "100.64.0.1",
                   "192.0.2.1", "0.0.0.0", "224.0.0.1", "::1", "fc00::1",
                   "fe80::1", "2001:db8::1", "::ffff:8.8.8.8", "::ffff:127.0.0.1"):
            for addresses in ([self.address(ip)], [self.address("8.8.8.8"), self.address(ip)]):
                with patch.object(socket, "getaddrinfo", return_value=addresses):
                    with self.assertRaises(odoo.OdooError):
                        odoo.endpoint(META["api_url"])

    def test_rejects_unsafe_urls(self):
        for url in ("http://odoo.example", "https://u:p@odoo.example",
                    "https://odoo.example/other", "https://odoo.example?x=y",
                    "https://odoo.example/#fragment", "https://odoo.example\n"):
            with self.assertRaises(odoo.OdooError):
                odoo.endpoint(url)

    def test_tls_pins_socket_and_verifies_original_hostname(self):
        address = self.address("8.8.8.8")
        sock, wrapped = Mock(), Mock()
        context = ssl.create_default_context()
        self.assertTrue(context.check_hostname)
        self.assertEqual(ssl.CERT_REQUIRED, context.verify_mode)
        with patch.object(socket, "socket", return_value=sock), \
                patch.object(odoo.ssl, "create_default_context", return_value=context), \
                patch.object(context, "wrap_socket", return_value=wrapped) as wrap:
            conn = odoo.PinnedHTTPS("odoo.example", 443, address)
            conn.connect()
            sock.connect.assert_called_once_with(("8.8.8.8", 443))
            sock.settimeout.assert_called_once_with(odoo.TIMEOUT)
            wrap.assert_called_once_with(sock, server_hostname="odoo.example")
            self.assertIs(wrapped, conn.sock)

    def test_transport_envelopes_bounds_redirects_and_no_retry(self):
        with patch.object(socket, "getaddrinfo", return_value=[self.address("8.8.8.8")]):
            client = odoo.Client(META["api_url"])
        cases = [(302, b""), (200, b"x" * (odoo.MAX_RESPONSE + 1)),
                 (200, b"not json"),
                 (200, json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"message": KEY}}).encode()),
                 (200, json.dumps({"jsonrpc": "2.0", "id": 999, "result": []}).encode())]
        for status, raw in cases:
            with patch.object(odoo, "PinnedHTTPS") as https:
                response = https.return_value.getresponse.return_value
                response.status, response.read.return_value = status, raw
                with self.assertRaises(Exception):
                    client.call("common", "authenticate", [])
                https.assert_called_once()
                https.return_value.request.assert_called_once()
                https.return_value.close.assert_called_once()
                if status == 200:
                    response.read.assert_called_once_with(odoo.MAX_RESPONSE + 1)
        with patch.object(odoo, "PinnedHTTPS") as https:
            response = https.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = json.dumps(
                {"jsonrpc": "2.0", "id": client.sequence + 1, "result": 7}).encode()
            self.assertEqual(7, client.call("common", "authenticate", ["test", "reader", KEY, {}]))
            request = https.return_value.request.call_args.args
            self.assertEqual(("POST", "/jsonrpc"), request[:2])
            self.assertEqual("authenticate", json.loads(request[2])["params"]["method"])

    def test_exception_details_never_printed(self):
        with patch.object(odoo, "Client", side_effect=OSError(KEY)):
            status, out, err = self.invoke("partners")
            self.assertEqual(1, status)
            self.assertEqual("", out)
            self.assertIn("request refused or failed", err)


if __name__ == "__main__":
    unittest.main()
