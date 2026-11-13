"""The shim names a provider's edge or servers failing a request (eOyrdJ).

Claude Code reports a Cloudflare challenge as "Failed to authenticate. API
Error: 403 Attention Required! | Cloudflare". That is not a credential
problem: it must be provider_challenge, checked before the auth class, and
read only from the runtime's failure and stderr, never from stdout.
"""
import importlib.util
import os
from pathlib import Path
import sys
import unittest

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
spec = importlib.util.spec_from_file_location('provider_edge_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)

CHALLENGE = ("clamp_runtime_failed: Claude Code reported a failed result: Failed to authenticate. "
             "API Error: 403 Attention Required! | Cloudflare")


def failed(**fields):
    return {"status": "error", **fields}


class ProviderEdgeClassificationTest(unittest.TestCase):
    def test_a_cloudflare_403_is_a_challenge_not_an_auth_error(self):
        failure = shim.runtime_failure(['{"type":"error","message":"%s"}' % CHALLENGE], "")
        self.assertEqual(shim.classify_provider_error(failed(runtime_failure=failure), "anthropic"),
                         "provider_challenge")
        self.assertEqual(shim.classify_provider_error(failed(stderr=CHALLENGE), "anthropic"),
                         "provider_challenge")

    def test_a_bare_403_or_a_bare_cloudflare_mention_is_not_a_challenge(self):
        # A 403 without the challenge page stays whatever it was before (Mira:
        # an authentication 403 is not a positively identified challenge).
        self.assertIsNone(shim.classify_provider_edge(failed(stderr="Failed to authenticate. API Error: 403 Forbidden")))
        self.assertEqual(shim.classify_provider_error(failed(stderr="authentication failed: 403 Forbidden"),
                                                      "anthropic"), "auth_expired")
        self.assertIsNone(shim.classify_provider_error(failed(stderr="fetching cloudflare.com failed"), "anthropic"))

    def test_provider_5xx_and_overload_are_transient(self):
        for text in ("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}",
                     "API Error: 503 Service Unavailable", "overloaded_error"):
            self.assertEqual(shim.classify_provider_error(failed(stderr=text), "anthropic"), "provider_transient", text)
        self.assertIsNone(shim.classify_provider_error(failed(stderr="exit status 503 from my script"), "anthropic"))

    def test_stdout_never_classifies_the_provider_edge(self):
        # The model can write these words; only the runtime's own report counts.
        self.assertNotIn(shim.classify_provider_error(failed(stdout=CHALLENGE), "anthropic"),
                         ("provider_challenge", "provider_transient"))
        self.assertIsNone(shim.classify_provider_edge(failed(stdout="API Error: 529 overloaded_error")))

    def test_a_successful_run_is_never_classified(self):
        self.assertIsNone(shim.classify_provider_error({"status": "ok", "stderr": CHALLENGE}, "anthropic"))


if __name__ == "__main__":
    unittest.main()
