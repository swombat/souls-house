"""Real Chaos against a synthetic loopback provider: no keys or model spending."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[1] / 'agent-runtime'
spec = importlib.util.spec_from_file_location('house_runtime_settings', RUNTIME / 'runtime_settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

@unittest.skipUnless(os.environ.get('CHAOS_TEST_BIN'), 'set CHAOS_TEST_BIN for real runtime smoke')
class HouseRuntimeTest(unittest.TestCase):
    def test_real_runtime_sends_scoped_bearer_to_house_chat_completions(self):
        received = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                received.append((self.path, self.headers.get('Authorization'), payload))
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                event = {'id': 'synthetic-house', 'object': 'chat.completion.chunk', 'created': 1,
                         'model': payload['model'], 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'house-runtime-ok'}, 'finish_reason': None}]}
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                event['choices'] = [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]
                event['usage'] = {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2, 'cost': 0}
                self.wfile.write(('data: ' + json.dumps(event) + '\n\ndata: [DONE]\n\n').encode())
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        binary = os.environ['CHAOS_TEST_BIN']
        with tempfile.TemporaryDirectory() as td:
            home = Path(td) / 'chaos'
            env = {k: os.environ[k] for k in ('PATH', 'LANG') if k in os.environ}
            env.update(HOME=td, CHAOS_HOME=str(home), CHAOS_BIN=binary,
                       SOULSHOUSE_APP_URL=f'http://127.0.0.1:{server.server_port}',
                       SOULSHOUSE_BEARER_TOKEN='synthetic-resident-bearer')
            with patch.dict(os.environ, env, clear=True):
                settings.prepare(home)
                result = subprocess.run([binary, 'exec', '--skip-git-repo-check', '--sandbox', 'read-only',
                                         '--provider', 'house', '-m', 'house/deepseek-v4.1-flash',
                                         '-C', td, '--json', 'Reply with the synthetic marker. Do not use tools.'],
                                        env=env, capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            self.assertIn('house-runtime-ok', result.stdout)
            self.assertTrue(received)
            for path, authorization, payload in received:
                self.assertEqual(path, '/api/v1/house_inference/chat/completions')
                self.assertEqual(authorization, 'Bearer synthetic-resident-bearer')
                self.assertEqual(payload['model'], 'house/deepseek-v4.1-flash')
                self.assertTrue(payload['stream'])
                self.assertTrue(payload['messages'])

if __name__ == '__main__':
    unittest.main()
