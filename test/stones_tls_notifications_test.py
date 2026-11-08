import importlib.util
import io
import json
import ssl
import time
import unittest
from unittest.mock import mock_open, patch, MagicMock


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


notice = load("stones_notice", "ops/deploy/stones-notify.py")
monitor = load("stones_monitor", "ops/deploy/check-stones-tls.py")


class NotificationsTest(unittest.TestCase):
    def test_notice_uses_exact_endpoint_and_never_prints_token(self):
        config = json.dumps({
            "url": "https://souls.house/api/v1/conversations/erBWle/messages",
            "token": "synthetic-private-token",
        })
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value = io.StringIO(
            '{"message":{"id":"receipt"}}'
        )
        with patch("builtins.open", mock_open(read_data=config)), \
                patch.object(notice.sys, "argv", ["notice", "Ready", "Fixed detail"]), \
                patch.object(notice.urllib.request, "build_opener", return_value=opener), \
                patch("sys.stdout", new_callable=io.StringIO) as out:
            notice.main()
        request = opener.open.call_args.args[0]
        self.assertEqual("Bearer synthetic-private-token", request.headers["Authorization"])
        self.assertNotIn("synthetic-private-token", out.getvalue())
        self.assertIn("receipt", out.getvalue())

    def test_redirects_are_forbidden(self):
        with self.assertRaises(ValueError):
            notice.NoRedirect().redirect_request(None)

    def test_public_monitor_checks_expiry(self):
        context = MagicMock()
        tls = context.wrap_socket.return_value.__enter__.return_value
        for days, fails in [(90, False), (20, True)]:
            tls.getpeercert.return_value = {
                "notAfter": time.strftime(
                    "%b %d %H:%M:%S %Y GMT", time.gmtime(time.time() + days * 86400)
                )
            }
            with patch.object(monitor.socket, "create_connection"), \
                    patch.object(monitor.ssl, "create_default_context", return_value=context):
                if fails:
                    with self.assertRaises(ValueError):
                        monitor.check("soulstones.fyi")
                else:
                    monitor.check("soulstones.fyi")
        self.assertEqual("tls-check.soulstones.fyi",
                         context.wrap_socket.call_args.kwargs["server_hostname"])

    def test_monitor_rejects_invalid_domain_before_network(self):
        with patch.object(monitor.socket, "create_connection") as network:
            with self.assertRaises(ValueError):
                monitor.check("https://house.example/private")
            network.assert_not_called()


if __name__ == "__main__":
    unittest.main()
