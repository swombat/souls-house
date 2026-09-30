# Agent Voices: Text-to-Speech Playback (v3 -- Final)

**Date**: 2026-02-22
**Status**: Final
**Requirements**: `/docs/requirements/260222-01-agent-voices.md`
**Previous**: `/docs/plans/260222-01b-agent-voices.md`
**Reviews**: `/docs/plans/260222-01a-agent-voices-dhh-feedback.md`, `/docs/plans/260222-01b-agent-voices-dhh-feedback.md`

## Executive Summary

Add on-demand voice playback to agent messages. When an agent has a configured ElevenLabs voice, a play button appears on its messages. Clicking it kicks off a background job that calls ElevenLabs TTS, attaches the audio via Active Storage, and notifies the frontend via the existing `Broadcastable` concern. Subsequent plays hit the cached attachment directly.

Changes from v2 based on DHH review:
- Add voice configuration UI to the agent edit page (identity tab) with a voice dropdown + custom ID option
- Add `voice_id` to `agent_params` and `json_attributes`
- Fix `updateMessage` helper to update both `recentMessages` and `olderMessages`
- Extract `csrfToken()` helper in `show.svelte` to DRY up repeated DOM queries
- Extract `blob_url_for` private helper in Message model
- Replace console seed step with UI-first approach (initial seed in deployment notes only)
- Add verification note for `HallucinationFixesController` site_admin behavior change

## Architecture Overview

```
User clicks play
    |
    v
POST /messages/:id/voice (JSON)
    |
    v
Messages::VoicesController#create (inherits Messages::BaseController)
    |-- voice_audio already attached? -> return URL immediately (200)
    |-- otherwise -> enqueue GenerateVoiceJob, return 202
    |
    v
GenerateVoiceJob
    |-- Message::SpeechText strips markdown
    |-- ElevenLabsTts.synthesize(text, voice_id:)
    |-- attach result as message.voice_audio
    |-- save! triggers Broadcastable refresh
    |
    v
ActionCable broadcast -> Inertia reloads messages -> voice_audio_url populated -> AudioPlayer plays
```

## Implementation Progress (Backend Steps 1-10, 14)

- [x] Step 1: Database Migration (AddVoiceIdToAgents)
- [x] Step 2: Agent Model Changes (voiced?, voice_id in json_attributes)
- [x] Step 3: Message Model Changes (voice_audio, voice_available, voice_audio_url, content_for_speech, blob_url_for)
- [x] Step 4: Message::SpeechText Value Object
- [x] Step 5: ElevenLabs TTS Library Class
- [x] Step 6: GenerateVoiceJob
- [x] Step 7: Messages::BaseController (DRY extraction + refactor)
- [x] Step 8: Messages::VoicesController
- [x] Step 9: Routes (resource :voice under messages)
- [x] Step 10: AgentsController Changes (voice_id params, available_voices)
- [x] Step 14: Chat.rb System Prompt Update (voice tonal tag instructions)

## Testing Progress

- [x] test/models/message/speech_text_test.rb
- [x] test/models/message_test.rb (voice_available, voice_audio_url)
- [x] test/models/agent_test.rb (voiced?)
- [x] test/jobs/generate_voice_job_test.rb
- [x] test/controllers/messages/voices_controller_test.rb
- [x] test/lib/eleven_labs_tts_test.rb
- [x] Verify existing retries/hallucination_fixes controller tests pass
