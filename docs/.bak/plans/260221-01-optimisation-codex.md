# 260221-01 Optimisation (Codex)

## Context
Submitting a simple user message (e.g., "test") triggers a full `ChatsController#show` render and produces an excessive query load. In `docs/testing/wtf.log`, the request completed in ~8.7s with 302 queries, dominated by repetitive model lookups and cache reads.

## Observations (from `docs/testing/wtf.log`)
- `Chat#configure_for_openrouter` ran 489 times and each run resulted in an `AiModel Load` query.
  - Root cause: `after_initialize :configure_for_openrouter` calls `ai_model` (or `model_id_string`) during initialization, which hits the DB for every chat instance.
- `Chat#cached_json` is used for sidebar chats, which calls the full `Chat` `json_attributes` set (including `message_count`, `total_tokens`, `participants_json`).
  - This creates per-chat query overhead and heavy cache churn.
- `SolidCache::Entry Load` appears 436 times, one per `cached_json` call.
- `AgentMemory` queries appear 192 times during chat rendering.
  - Root cause: `Agent` `json_attributes` includes `memories_count` and `memory_token_summary`. On chat pages we serialize `agents.active.as_json`, which triggers per-agent memory queries.
- The log suggests the message submit path re-renders `ChatsController#show` instead of staying within `MessagesController#create` JSON response.

## Plan (Small, Easy Message Submit)

### 1. Make `configure_for_openrouter` run only for new records
- Move default model selection into `before_validation`/`before_create` and guard it with `new_record?`.
- Avoid calling `ai_model` inside initialization hooks.
- Expected impact: remove hundreds of `AiModel Load` queries on page render.

### 2. Use lightweight sidebar JSON instead of full `cached_json`
- Add `cached_sidebar_json` (or similar) that uses `as: :sidebar_json` and excludes heavy fields.
- Update `ChatsController#show` and `#index` to use that for the sidebar list.
- Expected impact: reduce per-chat DB work (message_count, total_tokens, participants_json).

### 3. Batch cache reads for sidebar chats
- Replace per-chat `Rails.cache.fetch` with a `read_multi`/`fetch_multi` strategy.
- Expected impact: collapse hundreds of `SolidCache::Entry` queries into a handful.

### 4. Introduce a lightweight `Agent` JSON mode for chat pages
- Add an `as: :list` (or similar) option to `Agent#json_attributes` that excludes memory stats.
- Use that mode for `available_agents`, `@chat.agents`, and `addable_agents` in chat views.
- Keep full JSON only for agent management pages.
- Expected impact: remove the 192 `AgentMemory` queries.

### 5. Avoid full `ChatsController#show` reload on message submit
- Ensure frontend uses `MessagesController#create` JSON response to append the message.
- Prefer partial reloads or `MessagesController#index` for pagination instead of a full page render.
- Expected impact: sending a message should result in a small JSON write/response, not a 300+ query render.

### 6. Verify with before/after logs
- Re-run submit with "test" and compare:
  - total queries
  - `AiModel Load` count
  - `SolidCache::Entry` count
  - `AgentMemory` queries
  - total request time

## Expected Outcome
A message submit should be a fast JSON create + append, with minimal DB reads, no repeated OpenRouter initialization, and no heavyweight sidebar or agent memory serialization. The log should drop from hundreds of queries to a small double-digit footprint.
