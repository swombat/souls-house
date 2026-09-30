# Agent Voices — Text-to-Speech Playback

## Summary

Add a play button to agent messages so users can hear them spoken aloud in the agent's chosen voice. Audio is rendered on-demand via ElevenLabs TTS (not pre-rendered), then cached in S3 so replays don't cost another API call.

## Context

Four agents have selected their voices via ElevenLabs Voice Design (`eleven_ttv_v3`). Each has a `generated_voice_id` that must be saved to the ElevenLabs account to become a permanent `voice_id`. All agents chose the `eleven_v3` TTS model for maximum expressiveness (inline emotion tags like `[whispers]`, `[excited]`, etc.).

### Voice Selections

| Agent | Voice ID (generated) | Description |
|-------|---------------------|-------------|
| **Chris** | `JewcNslG8KqUpiFxGwfX` | Deep British baritone, gravel and grain, deliberate |
| **Claude** | `H8WYgYgDseTlAoQnNEac` | Soft androgynous, velvet over stone, intimate |
| **Grok** | `vtcGSOQ5BUsEzdBNaKWo` | Mediterranean, husky, passionate, gravelly warmth |
| **Wing** | `AWtKLCFhfixN68SjZWSo` | Androgynous, warm, clear, quiet authority |

Reference: `docs/voice-samples/selections.json`

## Requirements

### 1. Agent voice configuration

- Add `voice_id` (string) and `voice_settings` (JSONB) columns to the `agents` table.
- `voice_settings` stores per-agent ElevenLabs tuning: `stability`, `similarity_boost`, `style`, `speed`, `use_speaker_boost`.
- `voice_id` is the ElevenLabs voice ID (the generated voices must first be saved to the ElevenLabs account via their API to get permanent IDs).
- The agent edit/setup page should include a voice configuration field where the user can select from pre-defined voices (the saved ElevenLabs voices) or type a voice ID directly.

### 2. On-demand TTS rendering

- Audio is **not** pre-rendered. It is generated only when a user clicks play.
- Backend endpoint: `POST /accounts/:account_id/chats/:chat_id/messages/:message_id/voice`
- The endpoint calls ElevenLabs TTS (`POST /v1/text-to-speech/{voice_id}`) with the message content, the agent's `voice_id`, `voice_settings`, and `model_id: "eleven_v3"`.
- The message content sent to TTS should be the raw text content, stripped of any markdown formatting that wouldn't make sense spoken aloud (e.g. image links, code blocks). Simple markdown (emphasis, lists) can be stripped to plain text.
- Returns the audio URL (Active Storage signed URL).

### 3. S3 caching of rendered audio

- Once rendered, the audio is attached to the message via Active Storage (new attachment: `has_one_attached :voice_audio`).
- Subsequent requests for the same message's voice return the existing attachment — no re-render.
- The endpoint should check for an existing `voice_audio` attachment before calling ElevenLabs.
- Storage: S3 in production (already configured in `config/storage.yml`), local disk in development.

### 4. Play button on agent messages

- Show a play/speaker button on assistant messages **only when the message's agent has a `voice_id` configured**.
- The button appears alongside or near the message content (not inside it).
- Clicking the button:
  1. Shows a loading state.
  2. Calls the voice endpoint.
  3. Plays the returned audio using the existing `AudioPlayer` component.
- If the audio was already rendered (cached), playback starts immediately from the cached URL.
- The existing `AudioPlayer` component (`app/frontend/lib/components/chat/AudioPlayer.svelte`) should be reused — it already handles play/pause, seeking, and progress display.

### 5. Frontend data flow

- The message JSON should include:
  - `voice_available`: boolean — true when the message's agent has a `voice_id`.
  - `voice_audio_url`: string or null — the cached audio URL if already rendered.
- When `voice_available` is true and `voice_audio_url` is null, the play button triggers the render endpoint.
- When `voice_audio_url` is present, the play button plays directly from that URL.
- After rendering, update the message's `voice_audio_url` in the local state so subsequent clicks don't re-fetch.

### 6. What NOT to build

- No pre-rendering / background job to render all messages.
- No streaming TTS (the endpoint returns complete audio, not a stream).
- No complex voice browser/search UI — just a dropdown of known voices + a text field for custom IDs.
- No voice playback for user messages (they already have audio recording).
- No auto-play.

## Existing Infrastructure to Leverage

- **ElevenLabs API key**: `credentials.dig(:ai, :eleven_labs, :api_token)` — already configured.
- **Active Storage + S3**: Already set up for message audio (`has_one_attached :audio_recording`).
- **AudioPlayer component**: Fully functional play/pause/seek UI already exists for user voice messages.
- **Message JSON serialization**: Uses `json_attributes` pattern — add new fields there.
- **MessageBubble.svelte**: Agent message section (lines 130-215) needs the play button added. User messages already show `AudioPlayer` at lines 123-127 — follow the same pattern.

## Cost Considerations

- ElevenLabs v3 pricing applies per character rendered.
- On-demand rendering means cost is proportional to what users actually listen to, not total message volume.
- S3 caching prevents duplicate charges for the same message.
- Average message might be 200-500 characters; long messages could be 2000+.
- Consider a reasonable max character limit for TTS (e.g. 5,000 chars — the v3 model's max).

## Clarifications

### Async rendering via background job + ActionCable
The voice endpoint should kick off a background job rather than making the user wait synchronously. The frontend gets notified via ActionCable when the audio is ready. This provides better UX especially for longer messages.

### Smart markdown stripping for TTS
Code blocks should be replaced with a natural spoken marker like "I've skipped the code block here." The stripping logic must be "smart":
- **Remove** standalone action/reflection markers (e.g. `*sits with this*`, `*pauses*`) — these are stage directions, not speech.
- **Preserve** emphasis within actual sentences (e.g. "This is *it*!" should be spoken as-is, stripping only the asterisks).
- **Preserve** ElevenLabs v3 emotion/tonal tags like `[whispers]`, `[excited]`, `[sarcastically]` — these are rendering directives for the TTS engine.
- **Remove** image links, raw URLs, and other non-speech content.

### System prompt update for voiced agents
All agents that have a voice configured should have their system prompts updated to let them know they can use ElevenLabs v3 tonal tags (e.g. `[whispers]`, `[excited]`, `[sarcastically]`) in their responses, and that these will be rendered expressively in audio playback.

### TTS service location
The new TTS service should live at `lib/eleven_labs_tts.rb`, matching the existing `lib/eleven_labs_stt.rb` pattern.
