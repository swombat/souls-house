# Ruby Mock Audit

Date: 2026-05-03

Status: Daniel reviewed initial categories. Convert provider/API stubs to VCR by default; keep only the explicit carve-outs below.

## Policy

Ruby tests should prefer real Rails behavior and VCR-backed HTTP/API interactions. Provider-facing stubs are a maintenance burden and can hide real payload, streaming, request-shape, and adapter issues. Mock-based tests stay only when Daniel explicitly approves them, and each approved mock should carry a short justification for why VCR or a real integration path is not a better fit.

## Convert Or Revisit With VCR

All identified provider/API stubs in this audit have now either been converted to VCR/real behavior or moved into the explicitly approved carve-outs below.

## Approved Mock Carve-Outs

These can keep mocks/stubs with comments explaining why.

- `test/lib/elevenlabs_stt_test.rb`: keep request/service stubs rather than VCR. Recording realistic ElevenLabs transcription means committing large binary/audio interactions or giant cassettes, which is not worth it for routine coverage.
- `test/controllers/chats/transcriptions_controller_test.rb`: keep stubbing `ElevenLabsStt.transcribe` for controller behavior. The service boundary can be covered by the ElevenLabs unit/service test without forcing large audio cassettes into the controller suite.
- `test/jobs/database_backup_job_test.rb`: keep stubbing credentials, ENV, and database config. This protects local configuration parsing and command construction; VCR is not relevant because the behavior is not an external HTTP provider interaction.

## Still To Decide

- `test/tools/web_tool_test.rb`: currently uses WebMock request stubs for varied web outcomes. This may be acceptable because the tool intentionally tests timeout, redirect, and malformed-page behavior. Review separately from provider API stubs.

## Converted On 2026-05-03

- `test/controllers/github_integration_controller_test.rb`: now uses VCR for repo listing.
- `test/jobs/agent_initiation_decision_job_test.rb`: now uses VCR for one real RubyLLM decision and direct tests for decision execution/parsing.
- `test/jobs/all_agents_response_job_test.rb`: RubyLLM response path now uses VCR; only the local provider-availability seam remains stubbed.
- `test/jobs/consolidate_conversation_job_test.rb`: now uses VCR for memory extraction and direct tests for prompt/window/parser behavior.
- `test/jobs/generate_title_job_test.rb`: removed the prompt-constructor stub; happy path remains VCR-backed.
- `test/jobs/manual_agent_response_job_test.rb`: now uses VCR for the real agent response path.
- `test/jobs/memory_refinement_job_test.rb`: now uses VCR for consent yes/no and direct tests for prompt behavior.
- `test/jobs/memory_reflection_job_test.rb`: now uses VCR for promotion decisions and direct tests for parser/prompt/index behavior.
- `test/jobs/moderate_message_job_test.rb`: now uses VCR for moderation.
- `test/jobs/sync_github_commits_job_test.rb`: now uses VCR for commit sync.
- `test/models/github_integration_test.rb`: now uses VCR for commit sync.
- `test/models/oura_integration_test.rb`: now uses VCR for token revocation during disconnect.
- `test/tools/github_commits_tool_test.rb`: now uses VCR for GitHub sync/diff/file behavior and direct tests for truncation.
- `test/controllers/agents/telegram_tests_controller_test.rb`: now uses VCR for real Telegram `sendMessage` success/error behavior; bot token, chat id, bot/user metadata, and webhook-like secrets are scrubbed in cassettes.
- `test/controllers/agents/telegram_webhooks_controller_test.rb`: now uses VCR for real Telegram `setWebhook`/`getWebhookInfo` behavior. Current test credentials produce Telegram's real invalid-webhook-url response because the test app URL is not public HTTPS, so the controller test asserts the safe failure path rather than faking success.
- `test/jobs/all_agents_response_job_test.rb`: removed the `ResolvesProvider.api_key_available?` stub; the missing-key branch now temporarily sets `RubyLLM.config.anthropic_api_key` to a placeholder and restores it.
