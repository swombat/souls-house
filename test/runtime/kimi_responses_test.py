"""Native Responses smoke, using only a synthetic loopback SSE provider.

Run: CHAOS_TEST_BIN=/usr/local/bin/chaos python3 test/runtime/kimi_responses_test.py
No resident home, credentials, MCP servers, or hooks are copied into this test.
This verifies Chaos's wire compatibility, not live Kimi entitlement/availability.
Unknown custom model IDs need the explicit reasoning capability override that
trigger_shim.run_chaos applies only to Kimi; effort alone otherwise becomes null.
"""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
spec = importlib.util.spec_from_file_location('kimi_runtime_settings', RUNTIME / 'runtime_settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)
BINARY = shutil.which(os.environ.get('CHAOS_TEST_BIN', ''))


@unittest.skipUnless(BINARY,
                     'set CHAOS_TEST_BIN to an installed Chaos binary for loopback smoke')
class KimiResponsesTest(unittest.TestCase):
    def test_native_responses_stream_preserves_model_reasoning_and_client_identity(self):
        received = []
        refused = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_CONNECT(self):
                refused.append(self.path)
                self.send_error(403)

            def do_GET(self):
                if self.path == '/v1/models':
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({
                        'object': 'list', 'data': [
                            {'id': 'k3.1-pro', 'object': 'model', 'owned_by': 'synthetic'}],
                    }).encode())
                    return
                refused.append(self.path)
                self.send_error(403)

            def do_POST(self):
                if self.path != '/v1/responses':
                    refused.append(self.path)
                    self.send_error(403)
                    return
                payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                received.append((self.path, dict(self.headers), payload))
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Connection', 'close')
                self.end_headers()

                def event(kind, **data):
                    body = json.dumps({'type': kind, **data})
                    self.wfile.write(f'event: {kind}\ndata: {body}\n\n'.encode())
                    self.wfile.flush()

                message = {'id': 'msg_synthetic', 'type': 'message', 'role': 'assistant',
                           'status': 'completed', 'content': [
                               {'type': 'output_text', 'text': 'kimi-responses-ok', 'annotations': []}]}
                event('response.created', response={'id': 'resp_synthetic', 'status': 'in_progress'})
                event('response.output_item.added', output_index=0,
                      item={**message, 'status': 'in_progress', 'content': []})
                event('response.content_part.added', item_id=message['id'], output_index=0,
                      content_index=0, part={'type': 'output_text', 'text': '', 'annotations': []})
                event('response.output_text.delta', item_id=message['id'], output_index=0,
                      content_index=0, delta='kimi-responses-ok')
                event('response.output_text.done', item_id=message['id'], output_index=0,
                      content_index=0, text='kimi-responses-ok')
                event('response.output_item.done', output_index=0, item=message)
                event('response.completed', response={
                    'id': 'resp_synthetic', 'object': 'response', 'status': 'completed',
                    'model': 'k3.1-pro', 'output': [message],
                    'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}})

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            home = root / 'chaos'
            work = root / 'work'
            work.mkdir()
            url = f'http://127.0.0.1:{server.server_port}'
            # Do not inherit API keys, auth, resident root paths, hook variables,
            # MCP configuration, or proxy bypasses from the invoking session.
            env = {
                'PATH': '/usr/local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                'HOME': td, 'CHAOS_HOME': str(home), 'CHAOS_BIN': str(Path(BINARY).resolve()),
                'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_DATA_HOME': str(root / 'data'),
                'XDG_CACHE_HOME': str(root / 'cache'), 'TMPDIR': td,
                'AGENT_IDENTITY_PATH': str(root / 'empty-identity'),
                'AGENT_REPO_PATH': str(work),
                'AGENT_RUNTIME_DOCS_PATH': str(root / 'empty-docs'),
                'TRIGGER_BEARER_TOKEN': 'synthetic-trigger-token',
                'MOONSHOT_API_KEY': 'dummy-kimi-responses-key',
                # Unexpected HTTP(S) destinations are refused by the local mock,
                # never forwarded. The provider itself bypasses the proxy.
                'HTTP_PROXY': url, 'HTTPS_PROXY': url, 'ALL_PROXY': url,
                'NO_PROXY': '127.0.0.1,localhost',
            }
            with patch.dict(os.environ, env, clear=True):
                settings.prepare(home)
                provider = {**settings.DEFAULTS['model_providers']['kimi'], 'base_url': url + '/v1'}
                settings.command(home, 'set', 'model_providers.kimi', json.dumps(provider))
                shim_spec = importlib.util.spec_from_file_location(
                    'kimi_responses_shim', RUNTIME / 'trigger_shim.py')
                shim = importlib.util.module_from_spec(shim_spec)
                shim_spec.loader.exec_module(shim)
                real_run = subprocess.run

                def isolated_run(args, **kwargs):
                    # Exercise the production shim's provider/model/capability
                    # arguments, changing only persistence and execution safety.
                    self.assertIn('model_supports_reasoning_summaries=true', args)
                    self.assertIn('model_context_window=1048576', args)
                    args = list(args)
                    args.insert(2, '--ephemeral')
                    index = args.index('--headless')
                    args[index:index + 1] = ['--sandbox', 'read-only']
                    return real_run(args, cwd=work, **kwargs)

                for count, effort in enumerate(('high', 'max'), 1):
                    with self.subTest(effort=effort):
                        with patch.object(shim.subprocess, 'run', side_effect=isolated_run):
                            result = shim.run_chaos(
                                'k3.1-pro', 60, 'Reply with the synthetic marker. Do not use tools.',
                                True, provider='kimi', reasoning_effort=effort)
                        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
                        self.assertIn('kimi-responses-ok', result.stdout)
                        self.assertEqual(len(received), count)
                        self.assertEqual((received[-1][2].get('reasoning') or {}).get('effort'), effort)
            self.assertEqual(refused, [], 'runtime tried an unexpected HTTP endpoint')
            self.assertEqual(len(received), 2)
            for path, headers, payload in received:
                self.assertEqual(path, '/v1/responses')
                headers = {key.lower(): value for key, value in headers.items()}
                self.assertEqual(headers.get('authorization'), 'Bearer dummy-kimi-responses-key')
                self.assertEqual(payload['model'], 'k3.1-pro')
                self.assertIs(payload['stream'], True)
                self.assertIn(payload['reasoning']['effort'], ('high', 'max'))
                self.assertTrue(payload['input'])
                user_agent = headers.get('user-agent', '').lower()
                self.assertIn('chaos', user_agent)
                self.assertNotIn('codex', user_agent)
                self.assertNotIn('kimi', user_agent)


if __name__ == '__main__':
    unittest.main()
