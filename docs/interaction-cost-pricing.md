# Interaction cost estimates

When editing `app/models/chat/model_selection.rb`, also update
`AgentRuntimeInteractionCost` and its tests. Check both the catalogue model ID
and the direct provider ID (for example, `claude-opus-5.5` versus
`claude-opus-5-5`). Unknown models must remain unavailable, not inherit the price
of a similarly named predecessor or Pro variant.

## Rates verified September 27, 2026

USD per million tokens, standard processing / short context:

| Model | Input | Cache read | Cache write | Output |
| --- | ---: | ---: | ---: | ---: |
| GPT-6 Astra | 10 | 1 | 12.5 | 50 |
| GPT-6 Sol | 2 | 0.2 | 2.5 | 10 |
| GPT-6 Luna | 0.1 | 0.01 | 0.125 | 0.5 |
| Claude Opus 5.5 | 4 | 0.2 | 5 (5m) / 8 (1h) | 20 |
| Gemini 3.8 Flash, through December 31, 2026 | 0.75 | 0.075 | See below | 3.75 |
| Gemini 3.8 Flash, from January 1, 2027 | 1.5 | 0.15 | See below | 7.5 |

Primary sources fetched directly:

- https://developers.openai.com/api/docs/pricing
- https://platform.claude.com/docs/en/about-claude/pricing.md
- https://ai.google.dev/gemini-api/docs/pricing
- https://openrouter.ai/api/v1/models (base rates and routed cache rates)

Claude Haiku 5.5 (added October 7, 2026, launch day): input 0.1, cache read
0.01, cache write 0.125 (5m) / 0.2 (1h), output 0.5, from the OpenRouter
endpoint for `anthropic/claude-haiku-5.5` (Anthropic provider). OpenRouter also
lists a long-context tier above 100k prompt tokens (0.5 in / 2.5 out) that these
estimates do not model. Recheck against Anthropic's pricing page.

Claude Fable 5.2 (added November 9, 2026, launch day): input 8, cache read
0.2, cache write 10 (5m) / 16 (1h), output 40, from the OpenRouter endpoint for
`anthropic/claude-fable-5.2` (Anthropic provider, tag `anthropic`; the
`anthropic/fast` priority endpoint at double these rates is not modelled).
Earlier Fable ids keep the Fable 5 rule (10 / 50). Recheck against Anthropic's
pricing page.

Qwen3.8 Omni Flash (added October 8, 2026): input 0.15, cache read 0.016,
output 0.47, from the OpenRouter endpoint for `qwen/qwen3.8-omni-flash`
(Alibaba provider, the only one listed). No cache-write rate is quoted, so
creation tokens use the input rate. Text pricing only; audio/video input is not
modelled.

Inkling 2 Small (added November 13, 2026): OpenRouter-only selection
`thinkingmachines/inkling-2-small`, with no direct provider ID. Reference estimate
is input $0.30, cache read $0.03, output $1.00 per million tokens, from the
Together endpoint saved in the corpus's
`notes/inkling-2-small-2026-11-05/endpoints.json`
(`https://openrouter.ai/api/v1/models/thinkingmachines/inkling-2-small/endpoints`).
No cache-write rate is quoted, so creation tokens use the input rate.
The saved snapshot also lists PrimeIntellect at $0.15/$0.50 input/output,
Modal and Cloudflare at $0.30/$1.00, and Nebius at $0.30/$1.00 with $0.06
cache reads; other endpoints quote $0.03 cache reads. Routing is not pinned
by this catalogue entry, so this reference estimate can differ from actual
routed charges. The endpoints advertise reasoning support; the catalogue uses
the existing thinking-mode toggle, not a new provider-specific effort scale.

Gemini 4 Hydrogen (added November 13, 2026; announced November 12): flat input
1.50, cache read 0.075, output 7.50 per million tokens. Verified November 13
against OpenRouter's public
`https://openrouter.ai/api/v1/models/google/gemini-4-hydrogen/endpoints`
(standard Google global / Google AI Studio endpoints) and Google's
`https://ai.google.dev/gemini-api/docs/whats-new-gemini-4-hydrogen`.
Google confirms the direct id `gemini-4-hydrogen`, flat pricing across the full
1M context window, and $0.075/M implicit cache reads (95% discount). No
introductory expiry, December doubling, or context-length tier is applied.
Flex, priority and regional premiums are not modelled.
Direct explicit caching (`cachedContents` and `caches.create`) is unsupported;
unexpected direct creation tokens conservatively fall back to the input rate,
not a supported cache-write operation. Routed cache writes use only
OpenRouter's quoted $0.0833333333333333/M token rate, not a Google direct write
price. OpenRouter reports no implicit caching on its endpoints, unlike the
direct API. Storage-time charges are not modelled. Lume's November 13 check with
the house's system Google key returned GET model 200, confirming the direct ID.
Generation returned 402 (depleted prepayment) at default, low, high and xhigh,
as did Carbon: direct generation is unverified, blocked by the account balance,
not demonstrated to be a Hydrogen incompatibility. The Google-pinned OpenRouter
generation smoke test returned 200 (souls.house YZxogj, YWbDdl).
Google's guide explicitly lists low, medium, high (default), and xhigh
thinking levels and rejects minimal. Hydrogen has its own four-level profile,
not Carbon/Argon's three-level profile; no off or numeric budget is exposed.

Gemini 4 Carbon (added November 11, 2026): input 2, cache read 0.1, output 10
per million tokens through November 30, 2026; input 4, cache read 0.2, output
20 from December 1, selected by the interaction's date, not today's date.
Sources checked November 11: OpenRouter's public
`api/v1/models/google/gemini-4-carbon/endpoints` (standard Google / Google AI
Studio endpoints; flex and priority rates are not modelled) and Google's
`blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-4-carbon-now-available/`
announcement, which specifies the introductory-price expiry and $4/$20 rates.
Google's `ai.google.dev/gemini-api/docs/pricing` Standard table confirms these
dates, all input/output/cache-read rates, and implicit-only direct caching.
Routed cache writes use OpenRouter's $0.1875/M introductory token rate, doubled
from December, following the scheduled input-rate change as for Argon; that
future routed write rate has not been independently quoted. Direct explicit
caching is unsupported; unexpected creation tokens conservatively fall back to
the input rate. Cache reads use $0.1/M introductory,
$0.2/M thereafter, as for Argon. OpenRouter reports no implicit caching.
The direct id `gemini-4-carbon` is explicitly listed as the model code and
endpoint on `ai.google.dev/gemini-api/docs/models`; no authenticated direct
request was made for this integration.

Gemini 4 Argon (added October 13, 2026, its release day): input 2, cache read
0.1, output 10 through November 30, 2026, then input 4, cache read 0.2, output
20 from December 1, 2026, selected by the interaction's date. Source: the Gemini
API pricing page (ai.google.dev/gemini-api/docs/pricing, Standard paid tier,
read 2026-10-13), which matches the OpenRouter endpoint for
`google/gemini-4-argon`. Implicit caching only. Routed interactions use
OpenRouter's cache-write rate ($0.1875 at the launch input price, scaled with
the December change); direct interactions use the input rate. Direct id
`gemini-4-argon`, listed on ai.google.dev/gemini-api/docs/models.

Muse Wonder (added October 13, 2026, the day after Meta announced it): input 4,
cache read 0.2, output 20, from the OpenRouter endpoint for `meta/muse-wonder`
(Meta provider, `meta/muse-wonder-20261012`, the only endpoint). OpenRouter
lists no cache-write price and no implicit caching for it, so cache writes fall
back to the input rate. There is no direct Meta route in souls.house; it runs
through OpenRouter only.

MiniMax M3.1 Flash (added October 22, 2026, three days after MiniMax released
it): input 0.15, cache read 0.015, output 0.6, from the OpenRouter endpoint for
`minimax/minimax-m3.1-flash` (Minimax provider, `minimax/minimax-m3.1-flash-20261019`)
on 2026-10-22. No cache-write price is listed, so cache writes fall back to the
input rate. OpenRouter only, like MiniMax M3.

Mercury 3 (added October 22, 2026, three days after Inception released it):
input 0.10, cache read 0.01, output 0.35, from the OpenRouter endpoint for
`inception/mercury-3` (Inception provider) on 2026-10-22. These are Inception's
launch rates, 50% off the list price of 0.20 in / 0.70 out (Inception's
announcement, inceptionlabs.ai/blog/introducing-mercury-3). When the launch
discount ends, the row should move to the list price. No cache-write price is
listed, so cache writes fall back to the input rate. OpenRouter only; Inception
is a new group in souls.house.

GPT-6.1 Terra (added October 26, 2026, the day OpenAI released it; system card
deploymentsafety.openai.com/gpt-6-1-terra): input 1, cache read 0.05, cache
write 1.25, output 5, from the OpenRouter standard endpoint for
`openai/gpt-6.1-terra` (OpenAI provider, `openai/gpt-6.1-terra-20261026`) on
2026-10-26. The same provider lists flex (0.5 / 2.5) and priority (2 / 10)
tiers and a long-context tier above 272k prompt tokens (2 in / 7.5 out) that
these estimates do not model. Direct id `gpt-6.1-terra`. Same reasoning
controls as GPT-6.1 Sol (none to max). Recheck against OpenAI's pricing page,
which returned HTTP 403 from the house.

Kimi K3.1 Pro (added October 24, 2026, the day Moonshot AI released it,
kimi.com/en/blog/kimi-k3-1-pro): input 2, cache read 0.20, output 10, from the
OpenRouter standard endpoint for `moonshotai/kimi-k3.1-pro` (Moonshot AI
provider, `moonshotai/kimi-k3.1-pro-20261023`, mxfp4) on 2026-10-24. The same
provider also lists a "Highspeed" priority tier at 4 in / 20 out; souls.house
requests no service tier, so the standard rate applies. No cache-write price is
listed, so cache writes fall back to the input rate. OpenRouter only, like Kimi
K3, which it replaces in Top Models as Moonshot's flagship.

DeepSeek V4.1 Flash 1017 (added October 19, 2026, two days after DeepSeek
released the snapshot): input 0.15, cache read 0.003, output 0.6, from the
OpenRouter endpoint for `deepseek/deepseek-v4.1-flash-1017` (DeepSeek provider)
and DeepSeek's pricing page on 2026-10-19. These are the off-peak rates; DeepSeek
charges double at peak (01:00-04:00 and 06:00-10:00 UTC on weekdays), and the
estimate does not model the time of day. Cheaper third-party hosts exist on
OpenRouter. No cache-write price is listed, so cache writes fall back to the
input rate. OpenRouter only (no direct DeepSeek id for the dated snapshot).

Muse Spark Open (added October 16, 2026, the day after Meta released the open
weights): input 1.25, cache read 0.15, output 4.25, from the OpenRouter endpoint
for `meta/muse-spark-open` (Modal provider, `meta/muse-spark-open-20261015`, the
only endpoint; Meta does not serve it). No cache-write price is listed, so cache
writes fall back to the input rate. OpenRouter only.

Muse Ember (added November 10, 2026, the day after Meta released it): input 0.1,
cache read 0.004, cache write 0.125, output 0.5, from the OpenRouter endpoint for
`meta/muse-ember` (Meta provider, `meta/muse-ember-20261109`, the only endpoint).
Text pricing only; image/audio/video input is not modelled. OpenRouter only (no
direct Meta route in souls.house).

Gemini rates are selected by the interaction's date, preserving historical
promotional estimates. Google quotes cache **storage** by token-hour, not a
one-off cache-write rate. Do not convert that to a token price by assuming a
TTL. Creation tokens, if reported, use the standard input rate; storage is
excluded because storage duration is not in the interaction telemetry.
OpenRouter currently quotes a separate Gemini 3.8 cache-write token rate of
$0.0416666666666667 per million; only routed interactions use that rate
(scaled with the scheduled Gemini price increase).

Older model rates retain their existing verification date; this update does not
claim to have reverified the entire catalogue. GPT-6 Pro aliases are not covered
by the base-model rules.

## Scope and missing data

These are token-rate estimates, not provider bills. Aggregated trigger telemetry
does not identify each request's context-pricing tier, service tier, regional
uplift, tool charges or storage duration. Standard/short-context rates cannot
reconstruct those charges; the UI discloses these exclusions.

Reports calculate costs from stored usage at read time. Adding a price therefore
restores historical estimates where token categories are available; no backfill
or provider re-request is necessary. Incomplete telemetry remains unavailable.
Account and resident cost pages list excluded interactions by resident, model
and reason, even when there are no priced interactions at all.

## Verification (September 27, 2026)

- Focused Rails cost/report/controller coverage: 83 tests, 480 assertions, green.
- Cost-panel Vitest coverage: 3 tests, green.
- Chromium E2E: 2 tests, green (mixed and wholly unpriced accounts, plus mobile
  resident views). Screenshots are generated by `test/e2e/costs.spec.js`.
- Full Rails suite: 2,481 tests, 13,091 assertions, zero failures, four unrelated
  errors: a runtime test still references the removed Antigravity patch; one
  PNG fixture fails libvips decoding; two video tests require missing `ffmpeg`.
- Changed frontend files pass Prettier. Repository-wide checking still flags
  four untouched files. Changed Ruby files pass RuboCop using a temporary Ruby
  3.4 parser target; stock RuboCop cannot yet recognise this checkout's Ruby 4.0.

Run Rails through the instance test lock. Build Vite once before the parallel
suite and disable automatic rebuilds for that run; do not edit frontend sources
while the suite is using its manifest. The house's single-process test database
can also retain browser records in tables without fixtures; the normal parallel
suite uses its isolated worker databases.

No database migration or runtime-image rebuild is required for this change.
Production web deployment is a separate step from merging the source.

## October 2026 additions

OCTOBER_MODELS take their list prices from the OpenRouter catalogue
(`/api/v1/models`), reverified on 2026-10-26 (USD per million tokens,
input / output / cache read):
Qwen3.8 Max (`qwen/qwen3.8-max-0902`) 2 / 6 / 0.25; Qwen3.8 Max Prime 4 / 12 / 0.5;
GLM 5.3 0.0699 / 1.4 / 0.0689; GLM 5.3 Prime 2.8 / 8.8 / 0.56. Other Qwen and GLM
models added to the catalogue at the same time stay unpriced.

GLM 5.3 was first recorded on 2026-10-25 at 0.079 input and 0.078 cache read;
by 2026-10-26 OpenRouter listed the lower rates above. The other three were
unchanged. GLM 5.3's price has moved once already, so recheck it before
relying on old GLM 5.3 estimates.

## November 2026 additions

NOVEMBER_MODELS take their list prices from the OpenRouter catalogue and the
model's endpoint list (`/api/v1/models/<id>/endpoints`, single Z.AI route),
checked on 2026-11-03 (USD per million tokens, input / output / cache read):
GLM 5.3 FlashX Legal (`z-ai/glm-5.3-flashx-legal`) 0.37 / 1.25 / 0.075.
GLM 5.3 FlashX itself stays unpriced.
