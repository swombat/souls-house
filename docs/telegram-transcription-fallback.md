# Telegram transcription transport fallback

Transcription network failures are reported as `ElevenLabsStt::Error`, including
Net::HTTP open/read/write timeouts and OS-level `ETIMEDOUT`. Invalid JSON or an
unexpected successful response shape also becomes a transcription error.
An unrelated outer `Timeout::Error` is not converted by the transport handler.
OS errors are handled as `SystemCallError` only within the HTTP request boundary,
not through an enumerated errno list. This also includes local upload-read OS
errors encountered while streaming the request; the error says “request failed”
rather than assuming the remote service was unreachable. The original cause is
preserved.

Existing Telegram preparation handlers retain the raw attachment, record
`transcription_status: failed`, and continue to **media ready**, enqueueing a
resident wake even when no later message exists. This differs from operator
recovery that marks the entire media row **failed**. Both states release the
ordered-delivery gate; neither means the raw attachment was deleted.

Empty or absent transcription text remains a successful empty result, not a
failure. Callers can retrieve attached raw media through authenticated paths.

This change addresses the escaped transport timeout observed in the September
18 incident, reported by Claude and diagnosed in production by Mira. It does
not implement a stale-media sweeper, an overall processing deadline, or recovery
from a killed worker. Those require guarded state transitions and durable wake
retry independently of the terminal media state.
