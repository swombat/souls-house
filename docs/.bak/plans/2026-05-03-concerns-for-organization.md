# Concerns for Organization

## Goal

Apply the Rails concern organization pattern to Helix Kit where it improves navigation without changing behavior. The main targets are the oversized domain models whose methods already form recognizable traits:

- `Message`
- `Chat`
- `Agent`

The work should make the main model files read like tables of contents while keeping behavior on the domain objects.

## Source Pattern

This follows the `rails-best-practices-importer` guidance from `fizzy:concerns-for-organization` and the aligned Campfire model organization notes:

- Concerns are named traits, not generic helper buckets.
- A concern owns the associations, scopes, callbacks, constants, validations, and command/query methods that belong to that trait.
- Model-specific concerns live under the model namespace, such as `app/models/message/replayable.rb`.
- The public API stays on the model: callers still use `message.replay_for(...)`, `chat.archive!`, and `agent.memory_context`.
- Extract small collaborators only when the behavior is workflow-heavy enough that a plain object is clearer than a concern.

## Non-Goals

- Do not change persistence, routes, JSON shape, authorization, or frontend behavior.
- Do not introduce service-object ceremony.
- Do not split `Account` or `Membership` yet. They are smaller and currently cohesive enough.
- Do not move shared cross-model concerns such as `Broadcastable`, `JsonAttributes`, `ObfuscatesId`, or `SyncAuthorizable`.
- Do not rewrite model tests during extraction unless a test needs a require/autoload-friendly location.

## Test Cadence

Run the Rails suite throughout:

1. Before code changes: `bin/rails test`
2. After each extraction slice: focused Rails tests for the touched area
3. After a group of extractions: `bin/rails test`

Also run frontend checks from time to time:

- `yarn test:unit`
- `yarn test`

If a suite already fails before a slice, record the failure and avoid masking it.

## Implementation Slices

### Slice 1: `Message::Replayable`

Move provider-response and replay-continuity behavior out of `Message`:

- `REASONING_SKIP_REASONS`
- `reasoning_skip_reason`
- `reasoning_skip_reason_label`
- `thinking_signature`
- `record_provider_response!`
- `sync_tool_calls_from`
- `replay_for`
- replay payload builders
- provider-specific replay methods
- provider content/thinking/token extraction helpers

Likely focused tests:

- `test/models/message/replay_test.rb`
- `test/models/message/record_provider_response_test.rb`
- `test/models/message/reasoning_skip_test.rb`
- `test/models/message_thinking_test.rb`

### Slice 2: `Message::Attachable`

Move file and audio attachment behavior:

- attachment declarations and variants
- acceptable file type constants
- file validations
- `files_json`
- `audio_url`
- `voice_audio_url`
- `file_paths_for_llm`
- `pdf_text_for_llm`
- `audio_path_for_llm`
- blob/path/PDF extraction helpers

Likely focused tests:

- `test/models/message_test.rb`
- attachment-related controller tests such as transcription tests if impacted

### Slice 3: `Message::Streamable`

Move AI streaming and tool-status broadcasting:

- `stream_content`
- `stream_thinking`
- `stop_streaming`
- `broadcast_tool_call`
- `format_tool_status`
- `truncate_url`

Likely focused tests:

- `test/models/message_test.rb`
- chat streaming or sync tests if present

### Slice 4: `Message::HallucinationFixable`

Move hallucinated timestamp and tool-call repair behavior:

- `TIMESTAMP_PATTERN`
- `TOOL_RESULT_TYPES`
- timestamp and JSON-prefix detection
- `fixable`
- `strip_leading_timestamp`
- `fix_hallucinated_tool_calls!`
- loose JSON parsing and recovery helpers

Likely focused tests:

- hallucination fix controller/job tests
- `test/models/message_test.rb`

### Slice 5: `Message::Moderatable`

Move moderation state and callbacks:

- `MODERATION_THRESHOLD`
- moderation callback
- flagged/severity helpers
- queue helper

Likely focused tests:

- `test/models/message_test.rb`
- moderation controller/job tests

### Slice 6: `Chat::ModelSelection`

Move static model catalogue and model capability helpers:

- `MODELS`
- `model_config`
- `supports_thinking?`
- `supports_audio_input?`
- `supports_pdf_input?`
- `requires_direct_api_for_thinking?`
- `provider_model_id`
- `resolve_provider`
- instance model label/name helpers if they read better with the catalogue

Likely focused tests:

- `test/models/chat_test.rb`
- `test/models/chat_thinking_test.rb`

### Slice 7: `Chat::Archivable` and `Chat::AgentOnly`

Move simple lifecycle traits:

- archive/discard query methods and scopes where cohesive
- agent-only prefix, scopes, and query methods
- respondable helpers if they naturally belong with archive/discard

Likely focused tests:

- `test/models/chat_test.rb`
- controller tests for chat archive/discard resources

### Slice 8: `Chat::Initiable` and `Chat::Summarizable`

Move agent initiation and summary behavior:

- initiated scopes
- `initiate_by_agent!`
- invited-agent resolution
- summary staleness/generation/transcript helpers

Likely focused tests:

- `test/models/chat_initiation_test.rb`
- `test/models/chat_summary_test.rb`

### Slice 9: `Agent::Memory`, `Agent::Tools`, `Agent::Predecessor`

Move cohesive traits out of `Agent`:

- memory context and token accounting
- tool loading and validation
- predecessor upgrade flow

Keep `Agent::Initiation` as the reference shape.

Likely focused tests:

- `test/models/agent_test.rb`
- `test/models/agent_memory_test.rb`
- `test/models/agent_initiation_test.rb`

## Rollout Notes

- Prefer one concern extraction per commit.
- Keep method order inside concerns conventional: constants, `included`, class methods, public methods, private helpers.
- Include only the new concern in the parent model, then run focused tests before proceeding.
- If an extraction reveals hidden coupling, stop and either leave the code in the parent model or extract a small collaborator with a narrow name.
