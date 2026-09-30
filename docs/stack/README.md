# Dependency and integration references

These are dated summaries of upstream libraries/services, not claims that every
example or API is used by souls.house. Check each note's version/source against
`Gemfile.lock`, `bun.lock` and current upstream documentation before changing code.
[Architecture](../architecture.md) describes the application itself.

- [Inertia Rails](inertia-rails.md), [Svelte 5](svelte-5.md), [Action Cable](actioncable-streaming.md)
- [shadcn-style components](shadcn/index.md), [DaisyUI](daisyui.md)
- [Telegram API](telegram-bot-api.md), [ElevenLabs transcription](elevenlabs-stt.md)
- [GitHub OAuth/API](github-oauth-api.md), [Oura API](oura-api.md), [X gem](x-ruby-gem.md)

Unused Pay/billing, retired RubyLLM moderation and former Rails search-tool notes
are preserved under `docs/.bak/stack/`, not presented as installed capabilities.
