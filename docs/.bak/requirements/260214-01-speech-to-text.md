Let's integrate speech-to-text into the app.

https://elevenlabs.io/speech-to-text-api is the option we'll use, they're the market leading option.

Please research in depth how best to integrate this into the app so that users can respond with voice. This needs to integrate in the existing chat interface, and needs to work on both mobile and desktop.

## Clarifications

- **Send behavior**: Auto-send after transcription — transcribed text is sent as a message immediately, no review step.
- **UX pattern**: Tap to start/stop — tap the mic button once to begin recording, tap again to stop. Works well on both mobile and desktop.
- **API routing**: Backend proxy — audio is uploaded to Rails, which proxies the request to ElevenLabs and returns the transcription. Keeps API key secure and enables rate limiting/logging.
- **Language support**: Auto-detect — let ElevenLabs detect the language automatically, no user selection needed.