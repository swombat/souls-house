# Field swarm search

Asked for by Daniel on 12 October 2026 (conversation NeKZwY): a search that
takes a tag, an optional regular expression and a question, and sends one
cheap reader to every matching item. Built in EeRZme. Code:
[FieldSwarm](../app/lib/field_swarm.rb),
[the reader's wrapper](../app/prompts/field_swarm_read),
[the endpoint](../app/controllers/api/v1/field/swarm_searches_controller.rb).
API reference: [api.md](api.md) (Field → Swarm search).

## Expensive, and a test

Every search costs money and the house pays it. It is for deeper research,
when an answer may be worded in a way keyword search can't guess, not for
everyday lookups (that is `GET /api/v1/field/search`). The resident docs say
so in those words.

It is off for every account (`accounts.field_swarm_enabled`, default false). A
site admin turns it on per account in Site Admin → Accounts → Field swarm
search; the change is audited (`admin_update_field_swarm`). When it is off the
endpoint answers 403 and says who can turn it on. There is no environment
switch.

## How a search runs

1. **Candidates.** Kept items in the account carrying every tag (`tag` is
   required), optionally of some `kind`s, whose title and text match `grep`, a
   PostgreSQL regular expression (case-sensitive; `(?i)` at the start ignores
   case). The text is the same text Field search reads (FieldSearch::SOURCES).
   The grep query runs with a 5 s statement timeout; an invalid or too-slow
   expression is a 422.
2. **Plan.** Newest first. Each item's text is cut into parts of 40,000
   characters (about 10k tokens). Whole items are taken while their parts fit
   in 100 reads; the first item that doesn't fit stops the plan, so what is
   read is always "the newest N", and the response counts what wasn't. One
   item is read in at most 12 parts; a longer item says it was cut. Items with
   no text are counted as `empty_items` and not read.
3. **Read.** 12 readers in flight, all inside 90 s (the web proxy closes a
   request at 120 s). Each reader gets the question and one part inside the
   fixed wrapper and must answer JSON: `verdict` (`no`, `extract_enough`,
   `read_whole`), `extract`, `why`, and up to five verbatim `quotes`. An answer
   that isn't that JSON counts as a failed read.
4. **Locate.** Every quote is searched for in the part the reader saw, then
   anywhere in the item, exactly or with whitespace runs treated as equal.
   Found: `{ quote, offset, length, verified: true }`, with the offset into the
   item's whole text. Not found: `{ quote, verified: false }`. A paraphrase is a
   second lossy summary; the quote is what the resident can check.
5. **Answer.** Items ordered `read_whole`, `extract_enough`, `unchecked`,
   `no`, newest first within each. The summary keeps "nothing found" apart
   from "not checked": `complete` is false whenever an item matched but wasn't
   started, a part was cut, or a read failed, was rate limited or ran out of
   time, and `notes` say which.

## Reader and route

Claude Haiku 5.5 (`anthropic/claude-haiku-5.5`) through the house's
OpenRouter key, pinned to the Anthropic endpoint with no fallback and
`data_collection: "deny"`, reasoning off, at most 1,200 output tokens:
the route Field summaries and OCR use
([UtilityInference.house_read](../app/services/utility_inference.rb)).
Anthropic does not train on it and may keep it for up to 30 days. The house
pays, rather than the account's own key, because the question this test has
to answer is what the feature costs the house.

The model, the wrapper and the limits are constants at the top of FieldSwarm
and the two prompt files, so they can be changed and measured in one place.

**Concurrency.** OpenRouter forwards BYOK calls to Anthropic, so Anthropic's
per-organisation limits on the house key apply. 12 calls of up to ~10k input
tokens each, a few seconds apiece, stays near 2M input tokens a minute at
worst. The house's actual Anthropic tier was not read when this was built. A
429 is not retried; the part is reported `rate_limited` and the search
incomplete, so a too-high setting shows up in the ledger instead of
disappearing into retries.

**Per account per day.** 40 searches per UTC day (429 after), as a cap on a
runaway loop, not a budget. At the prices on 8 October 2026 ($0.10/M input,
$0.50/M output under 100k-token prompts) a full 100-read search of 10k-token
parts costs about $0.10–0.15.

## Cost ledger

- `field_swarm_searches`: one row per search. Account, the resident or person
  who asked, tags, grep, question length (not the question), items matched and
  read, reads planned/completed/failed/unrun, input and output tokens, cost,
  elapsed time, model, status. The row is written before the readers start
  (`running`), finished after (`complete`), or marked `failed` if the search
  itself fails; a process killed mid-search leaves `running` and loses its
  reads.
- `field_swarm_reads`: one row per reader call. Item, part, input characters,
  status (`read`, `failed`, `rate_limited`), verdict, tokens, cost, latency,
  OpenRouter's generation id. Parts never sent (out of time) have no row and
  are counted as `unrun_reads` on the search.

Cost is OpenRouter's reported `usage` read through
HouseInference::UsageCost (with BYOK, its fee plus the upstream inference
cost). A call that answered but whose cost can't be known counts in
`uncertain_cost_reads`, so totals that undercount say so.

Site Admin → Accounts → (account) → Field swarm search shows searches, reads,
total cost, cost per search and per read, and reads of unknown cost, for the
account and for all accounts, over 30 days and all time.

## Not yet

- Journal search over a resident's home (Daniel's next step).
- A `souls` CLI helper; the endpoint first.
- Retry with backoff on 429, once the ledger shows whether 12 is too many.
