# Kimi Code subscription keys

Add the key from [Kimi Code Console](https://www.kimi.com/code/console) in
**Account settings → Agent API keys → Kimi Code subscription**, then explicitly
select a model in **Kimi Code subscription** in the resident's settings.
The existing encrypted `moonshot_api_key` field / `MOONSHOT_API_KEY` environment
variable is retained; no key migration or OAuth login is required.

The `kimi` Chaos provider uses native Responses at
`https://api.kimi.ai/coding/v1`. Existing `moonshotai/*` selections remain on
OpenRouter with separate billing; adding a Code key does not change a resident's
model or billing route. Standard Moonshot platform PAYG keys are not accepted by
the Code endpoint. They have no direct route in this integration.
Subscription selections never fall back to OpenRouter when a key is missing.

The six exact model IDs and their effort defaults come from the
[official model page](https://www.kimi.com/code/docs/en/kimi-code/models.html),
checked November 3, 2026:

| Selection suffix | Model | Default effort |
| --- | --- | --- |
| `k3.1-pro` | K3.1 Pro | high |
| `k3.1-pro-highspeed` | K3.1 Pro Highspeed | high |
| `k3` | K3 | high |
| `k3-256k` | K3 256K | high |
| `kimi-for-coding` | K2.8 Preview | max |
| `kimi-for-coding-highspeed` | K2.7 Code Highspeed | fixed on |

House selections prepend `kimi-code/`; the runtime sends only the suffix.
Invalid IDs and disabled thinking can silently select another model at Kimi,
so the house refuses them. Adjustable efforts are low/high/max; the highspeed
K2.7 model stays on. The detailed model page supplies defaults (its overview
disagrees about K3.1's default); the house sends them explicitly. Chaos needs
the model reasoning capability enabled for these unfamiliar Responses IDs;
the shim sets it for Kimi only. Documented maximum context is 1M except
K3 256K and K2.7 Code Highspeed at 256K; actual access also depends on the plan.

The [Codex guide](https://www.kimi.com/code/docs/en/third-party-tools/codex.html)
documents this API-key/Responses route. The
[community guidelines](https://www.kimi.com/code/docs/en/kimi-code/community-guidelines.html)
restrict subscriptions to personal interactive use, prohibit unattended batch
use and resale, and require truthful client identity. No client impersonation
is configured. This integration adds no scheduled jobs or model changes.
Account owners remain responsible for permitted use.

## Verification and rollout boundary

Dummy-key tests cover settings, exact routing, missing credentials, effort
guards and the actual Chaos Responses stream against a local test server.
They do not establish live Code Console authentication, membership access,
quota, or returned model identity. Before claiming a particular account works,
check its endpoint model list and one authorised interactive inference using
its own key, without logging that key. Documentation alone is not a live test.

Rails release and the updated resident runtime are both needed. Rollback is an
explicit choice of the previous OpenRouter model, not automatic fallback.
No resident is switched or restarted by these code changes. Subscription turns
are marked non-metered; the zero marginal API cost is not a quota measurement
or an estimate of the subscription price.
