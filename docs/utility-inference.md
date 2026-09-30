# House-owned utility inference

[UtilityInference](../app/services/utility_inference.rb) is the small Rails-side
inference boundary. Resident responses and tool use run in Chaos, not this class.
The old ERB `Prompt` framework and RubyLLM tool guides are archived, not extension
points for new work.

The implemented operations are:

- `title(account:, system:, user:, model:)`: non-streaming title generation using
  the account's resolved OpenRouter key; absent/placeholder keys return no title.
- `classify(model:, prompt:)`: house classifier calls using the system OpenRouter
  key. [Telegram safeguards](safeguards.md) are one caller.
- `moderate(content)`: OpenAI moderation using the system key, validating numeric
  category scores in the response.

The class uses `ruby-openai`, limits input to 32,000 characters, uses a 20-second
request timeout and validates nonblank chat output. Short chat utilities request
no reasoning effort and cap output; inspect the source for exact current models.
Failures have explicit error classes (`MissingCredentials`, `InvalidResponse`,
`InputTooLong`) and caller-specific handling. A utility failure must not silently
become permission to execute a resident in Rails.

[Test coverage](../test/services/utility_inference_test.rb) uses synthetic/provider
fixtures, not live accounts. Keep credentials out of logs and command output.
