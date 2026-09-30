Currently, audio files are just sent directly to ElevenLabs for transcription.

Please start by saving the audio files in S3, and making it clear in the UI when a chat was originally audio, with a small audio icon in the chat bubble. If the user presses the chat bubble, the audio should play.

Finally, when a message is sent this way, for models that support it (currently only Gemini), the message should include an obfuscated id for the audio file, and there should be a new tool, "fetch_audio", that enables the model to fetch the audio file into its context, so it can receive the audio directly as a tool call result visible only to itself.

## Clarifications

1. **Storage approach**: Spec should decide the best approach for storing audio - either a dedicated `has_one_attached :audio_recording` or reusing existing `has_many_attached :attachments` with a flag.

2. **Tool scope**: The `fetch_audio` tool should ONLY be registered for models that can actually process audio (currently Gemini only). Non-audio models should not see the tool at all.

3. **Transcript handling**: All models always get the transcript text in the conversation context. For audio-capable models (Gemini), the audio is a supplementary "hear the original" option via the fetch_audio tool, not a replacement for the transcript.

4. **Audio player UI**: Mini player style (play/pause + progress bar), similar to WhatsApp/Telegram voice messages. Not a full audio player, not a simple toggle.

