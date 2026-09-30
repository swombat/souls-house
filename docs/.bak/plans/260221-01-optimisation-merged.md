# 260221-01 Optimisation (Merged)

## Context
Submitting a simple message (e.g., "test") currently triggers full `ChatsController#show` work, leading to thousands of log lines, multi-second latency, and hundreds of redundant queries. The heavy work is dominated by repeated OpenRouter configuration, sidebar JSON generation, avatar existence checks, and agent memory summaries, plus extra reloads from moderation/broadcasts.

## Key Observations
- `Chat#configure_for_openrouter` runs on every Chat initialization and triggers 489 `AiModel` queries.
- Sidebar rendering triggers hundreds of per-chat cache reads and expensive JSON methods (`message_count`, `total_tokens`, `participants_json`).
- `Agent` JSON includes `memories_count` and `memory_token_summary`, which causes a large `AgentMemory` query storm.
- `ModerateMessageJob` updates messages in a way that likely triggers extra broadcasts/reloads.
- Avatar existence checks hit S3 repeatedly.
- Message send path uses Inertia redirect flow, causing full show renders; ActionCable then reloads props again.

## Merged Plan (Ordered by Impact)

### 1) Stop OpenRouter N+1 on init
- Avoid loading `ai_model` inside `configure_for_openrouter`.
- Use the foreign key (`ai_model_id`) instead of the association in the presence check.

### 2) Make sidebar JSON lightweight and cacheable
- Use `as: :sidebar_json` in the sidebar to avoid `message_count`, `total_tokens`, `participants_json`.
- Add a dedicated cached sidebar JSON path (with its own cache key).

### 3) Batch cache reads for sidebar chats
- Replace per-chat cache fetches with a single `read_multi` + write for misses.

### 4) Avoid expensive props on partial reloads
- Build `ChatsController#show` props conditionally based on `X-Inertia-Partial-Data`.
- Only compute `chats`, `agents`, `available_agents`, etc. when requested.

### 5) Remove agent memory stats from chat page JSON
- Add a lightweight `Agent` JSON mode (`as: :list`) that excludes memory stats.
- Use that mode for chat page props.

### 6) Skip broadcasts from moderation updates
- Use `update_columns` in `ModerateMessageJob` to avoid callbacks/broadcasts.

### 7) Cache avatar existence checks
- Cache `avatar_file_exists?` to avoid repeated S3 calls.

### 8) Make message submit a small JSON operation
- Send message creation via `fetch` with JSON response instead of an Inertia redirect.
- Rely on ActionCable updates, with the existing streaming refresh safety net.

## Verification
- Re-run “send test” and compare:
  - total query count
  - `AiModel Load` count
  - `SolidCache::Entry Load` count
  - `AgentMemory` queries
  - total request time
