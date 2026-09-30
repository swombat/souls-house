# Telegram Inbound Media for Residents

## Summary

Extend the existing two-way Telegram direct-message channel so a souls.house
Resident can receive:

- photos and image captions;
- Telegram voice notes;
- videos and video captions.

The first implementation should use the boundaries that already exist:

- Telegram webhooks and `ProcessTelegramUpdateJob` for receipt;
- `TelegramMessage` as the durable conversation record;
- Active Storage and the production S3 service for private files;
- the Resident API bearer token for authenticated downloads;
- `ElevenLabsStt` for speech-to-text;
- `ffmpeg`/`ffprobe` in the Rails application container for bounded video
  preprocessing;
- `ExternalAgentTelegramRequest` and the existing persistent Telegram Chaos
  session for the Resident wake.

Do not make media public and do not put Telegram bot tokens, Telegram file
paths, S3 URLs, or file bytes into the Chaos trigger payload.

This plan deliberately keeps current internal names such as `Agent`,
`HelixKit`, `helixkit-send-telegram`, and the repository folder. Product-facing
copy introduced or touched by this work should say **souls.house** and
**Resident**. A broad internal rename is separate work.

## Desired Experience

### Photo

1. Daniel sends Wing a photo, optionally with a caption.
2. souls.house stores the original privately.
3. Wing wakes in the existing Telegram thread.
4. Wing's prompt contains the caption, media metadata, and an authenticated
   download command.
5. Wing downloads the image into the hosted runtime and inspects it with
   Chaos's existing image tooling before deciding whether to reply.

### Voice

1. Daniel sends Wing a Telegram voice note.
2. souls.house stores the original recording privately.
3. souls.house transcribes it with the existing speech-to-text integration.
4. Wing wakes with the transcription in the prompt and can fetch the original
   recording if the audio itself matters.
5. If transcription fails, Wing still receives a grounded notice and access to
   the original recording.

### Video

1. Daniel sends Wing a video, optionally with a caption.
2. souls.house stores the original privately.
3. souls.house extracts bounded metadata, a small set of representative frames,
   and an audio transcription when an audio track is present.
4. Wing wakes with the caption, transcription, metadata, frame download paths,
   and original-video download path.
5. Wing can inspect the frames as images and fetch the original if needed.

## Non-goals for the First Version

- Sending photos, voice notes, or videos *from* a Resident back to Telegram.
- Native video input to an LLM.
- Passing media bytes through the Rails-to-runtime trigger request.
- Automatically attaching an image as structured Chaos input.
- Supporting Telegram groups, channels, albums, live photos, animations,
  stickers, or arbitrary documents.
- Replacing ElevenLabs STT.
- A general-purpose media pipeline shared with ordinary souls.house chats.
- The broad HelixKit-to-souls.house internal rename.

Photos sent as a Telegram media group may arrive as independent updates in the
first version. Album-level grouping can be added later if Residents find the
separate wakes confusing.

## Existing Ground

The current path is:

```text
Telegram webhook
  -> TelegramWebhooksController
  -> ProcessTelegramUpdateJob
  -> TelegramMessage
  -> TelegramAgentTriggerJob
  -> ExternalAgentTelegramRequest
  -> ChaosTriggerClient
  -> hosted trigger_shim.py
  -> chaos exec
```

Media is currently discarded by the text-only guard in
`ProcessTelegramUpdateJob`:

```ruby
text = message.dig("text")
return if text.blank?
```

The surrounding infrastructure already provides:

- webhook authentication;
- account-bound Telegram subscriptions;
- duplicate protection through Telegram message IDs;
- persistent per-subscription Chaos sessions;
- private S3-backed Active Storage;
- authenticated attachment-download patterns for ordinary conversations;
- speech-to-text;
- `ffmpeg` and `ffprobe` in the Rails production image;
- local-image understanding in Chaos.

The hosted Resident image contains `curl` but not `ffmpeg`. Video preprocessing
therefore belongs in the Rails application, not in each Resident container.

## Data Model

### Migration

Add media state to `telegram_messages`:

```ruby
add_column :telegram_messages, :media_kind, :string
add_column :telegram_messages, :caption, :text
add_column :telegram_messages, :transcription, :text
add_column :telegram_messages, :media_status, :string
add_column :telegram_messages, :media_error, :string
add_column :telegram_messages, :media_metadata, :jsonb, null: false, default: {}
add_column :telegram_messages, :wake_enqueued_at, :datetime
```

Use these values:

- `media_kind`: `photo`, `voice`, or `video`; `nil` for text-only messages.
- `media_status`: `pending`, `ready`, or `failed`; `nil` for text-only messages.

Keep the existing non-null `text` column. It remains the concise,
Resident-facing representation used by transcripts:

- text-only message: exact Telegram text;
- photo while pending: caption plus `[Photo — processing]`;
- photo when ready: caption, or `[Photo]`;
- voice while pending: caption plus `[Voice message — processing]`;
- voice when ready: caption and transcription, or `[Voice message]`;
- video while pending: caption plus `[Video — processing]`;
- video when ready: caption and transcription, or `[Video]`.

Keeping `text` populated avoids a nullable-content migration and preserves the
existing transcript contract. `caption` and `transcription` retain provenance
so generated text is not confused with words typed by the sender.

### Attachments

Add directly to `TelegramMessage`:

```ruby
has_one_attached :media
has_many_attached :preview_frames
```

Do not include `Message::Attachable`: that concern assumes an ordinary chat
message and contains behavior that does not fit Telegram conversations.

Add model methods for:

- media-kind and media-status validation;
- `media?`, `photo?`, `voice?`, and `video?`;
- a normalized transcript line;
- API metadata for the original and preview frames;
- rebuilding `text` from caption, transcription, kind, and status.

Limit `media_error` to a short operational category safe to show to a Resident.
Detailed provider responses and command stderr belong in server logs, not in
the conversation transcript.

## Receipt and Preparation

### 1. Parse Supported Telegram Message Shapes

Refactor `ProcessTelegramUpdateJob#perform` so `/start` remains text-only, while
direct messages accept text or one supported media shape.

Recognition order:

1. `/start`;
2. text;
3. photo;
4. voice;
5. video;
6. ignore unsupported message types.

For photos, select the largest `PhotoSize` entry. Capture only the Telegram
`file_id` needed for the immediate download job; do not persist the bot-scoped
download URL.

Read the optional `file_size` from the selected photo, voice, or video object.
If it exceeds the configured product limit, fail immediately with the
kind-specific size message instead of enqueueing a download that Telegram will
reject. Keep the streaming limit below as defense in depth because `file_size`
is optional and must not be trusted as the only bound.

For each supported direct message:

1. Find the subscription from the private Telegram chat ID.
2. Update username and blocked state as today.
3. Create one `TelegramMessage`, preserving the existing unique Telegram
   message-ID protection.
4. For text, enqueue `TelegramAgentTriggerJob` immediately.
5. For media, set `media_status: "pending"` and enqueue
   `PrepareTelegramMediaJob`.

The job argument may carry the Telegram `file_id` because Solid Queue stores it
inside souls.house. It must not be logged or sent to Chaos. If avoiding the
queue argument is preferred, add an encrypted `telegram_file_id` column and
clear it after preparation; carrying it ephemerally is simpler and avoids
retaining Telegram identifiers.

### 2. Add Bounded Telegram File Downloading

Extend `TelegramNotifiable` with narrow methods rather than exposing a generic
arbitrary-URL downloader:

```ruby
telegram_file_info(file_id)
telegram_download_file(file_path, max_bytes:)
```

Behavior:

1. Call Telegram `getFile` through the existing bot API boundary.
2. Classify unsuccessful results as permanent or transient rather than raising
   one undifferentiated error. In particular, Telegram's `file is too big`
   response is a permanent size failure and must not enter the retry policy.
3. Build the Telegram file URL internally.
4. Stream the response into a binary `Tempfile`.
5. Abort as soon as the configured byte limit is exceeded.
6. Never log the full download URL because it contains the bot token.
7. Return the tempfile plus safe metadata to the preparation job.

Initial souls.house product limits:

- photo: 20 MB;
- voice: 20 MB;
- video: 20 MB.

Keep these as explicit application constants. If Telegram's deployed API
ceiling changes, the application should still enforce its own bounded resource
policy.

The hosted Telegram Bot API currently refuses `getFile` downloads above 20 MB,
so oversize video commonly fails before any byte stream begins. Handle both
paths:

- preflight the optional webhook `file_size` for a fast user-facing answer;
- translate Telegram's `file is too big` response into the same permanent size
  failure;
- retain the streaming byte cap for absent, inaccurate, or changing metadata.

Use explicit exception classes, for example:

```ruby
TelegramMediaError < TelegramError
TelegramMediaTransientError < TelegramMediaError
TelegramMediaPermanentError < TelegramMediaError
TelegramMediaTooLarge < TelegramMediaPermanentError
```

Only transient errors participate in `retry_on`.

Validate content from downloaded bytes, not only Telegram metadata:

- use Marcel/Active Storage content identification;
- allow JPEG, PNG, WebP, and GIF for photos;
- allow OGG/Opus, MPEG, MP4 audio, M4A, WAV, and WebM for voice/audio;
- allow MP4, QuickTime, and WebM for video;
- give attachments a deterministic filename based on message ID and detected
  extension.

Animated GIF handling can remain image-only in the first version.

### 3. Prepare Media Asynchronously

Create `PrepareTelegramMediaJob`.

Responsibilities:

1. If the message is `ready` and `wake_enqueued_at` is present, return.
2. If the message is `ready` but `wake_enqueued_at` is absent, enqueue
   `TelegramAgentTriggerJob`, stamp `wake_enqueued_at`, and return.
3. Download and validate the file.
4. Attach the original to `telegram_message.media`.
5. Perform kind-specific preparation.
6. Set `media_status: "ready"` and rebuild `text`.
7. Enqueue `TelegramAgentTriggerJob`.
8. Stamp `wake_enqueued_at`.

On a permanent validation or size error:

1. set `media_status: "failed"`;
2. store a safe `media_error` category;
3. rebuild `text` to state that the media could not be received;
4. notify the Telegram sender with a concise explanation;
5. do not wake the Resident solely for an unreadable upload.

On a transient network/provider failure, raise and use a bounded `retry_on`
policy. Attachment and processing steps must be idempotent so retries do not
create duplicate blobs, frames, or messages.

The existing Telegram message-ID uniqueness remains the outer duplicate guard.
The ready-to-wake handoff must explicitly provide **at-least-once**, not
exactly-once, delivery. Solid Queue writes to a separate queue database, so the
primary-database status update and job enqueue cannot be one atomic
transaction. `wake_enqueued_at` closes the lost-wake window: a retry repairs a
ready message whose enqueue was never stamped. A crash after enqueue but before
the stamp may produce a rare duplicate wake; that is preferable to silent loss,
and the existing `SessionBusy` behavior serializes concurrent Telegram runs.

## Kind-specific Processing

### Photos

No server-side interpretation is required.

Store:

- original image;
- detected content type and byte size through Active Storage;
- Telegram-provided width and height in `media_metadata` when present.

The Resident receives a secure download path and instructions to:

```bash
curl -L \
  -H "Authorization: Bearer $HELIXKIT_BEARER_TOKEN" \
  "$HELIXKIT_APP_URL<authenticated_download_path>" \
  -o /home/agent/work/telegram-<message-id>.<ext>
```

The prompt should explicitly say to inspect the downloaded file with the
available image tool rather than infer its contents from the caption.

### Voice

After attaching the original:

1. pass a tempfile/upload-compatible wrapper to `ElevenLabsStt.transcribe`;
2. store returned text in `transcription`;
3. record duration and detected content type in `media_metadata`;
4. rebuild the normalized `text`.

The wrapper must respond to `original_filename` and `content_type` with the
detected values. Passing a bare `Tempfile` would make `ElevenLabsStt` label an
OGG/Opus voice note as its default `audio.webm`.

Preserve a voice caption and include it in normalized text exactly as for video.
If ElevenLabs returns `nil` from a successful request because no speech was
detected, leave the transcription absent and use the caption or
`[Voice message]`; do not mark transcription as failed.

Transcription failure should not discard the recording or mark the whole media
message failed. Record:

```json
{
  "transcription_status": "failed"
}
```

Then wake the Resident with access to the original recording and a clear
statement that no transcription was available.

Do not silently present machine transcription as the sender's exact written
words. Label it as a transcription in prompts and API output.

### Video

Create a small PORO under `app/lib`, for example
`TelegramVideoPreview`, to keep command construction, time calculations, and
tempfile cleanup out of the job.

Processing:

1. Run `ffprobe` with an argument array, never shell interpolation.
2. Record duration, dimensions, codecs, and whether an audio stream exists.
3. Extract at most six JPEG frames into tempfiles without attaching them yet.
4. Choose timestamps across the duration, excluding near-identical start/end
   edges where practical.
5. Resize frames to a maximum 1280-pixel edge and strip metadata.
6. If audio exists, extract a bounded mono audio file and transcribe it through
   `ElevenLabsStt`.
7. Once transcription has either succeeded or been recorded as unavailable or
   failed, attach every generated frame in one ordered `attach` call as the last
   video-preparation step.

Resource bounds:

- hard command timeout;
- at most six frames;
- no frame larger than the chosen display bound;
- no unbounded stderr capture;
- all tempfiles removed in `ensure`;
- no re-encoding or transcoding of the stored original.

If frame extraction fails but the original video is valid, retain the original,
record `preview_status: "failed"`, and continue. Likewise, failed audio
transcription should not make the video unavailable.

`has_many_attached` appends by default. Never attach preview frames
incrementally: a retry after partial success would duplicate and reorder them.
Building the full ordered attachment list first and attaching once at the last
step makes retries safe. If a prior attempt could have reached attachment before
raising, purge the existing `preview_frames` before the final replacement.

The Resident should receive the strongest truthful representation available:
caption, transcription, frames, metadata, and original—not a claim that the
video was understood merely because preprocessing ran.

## Authenticated Resident API

Extend the existing Telegram conversation API rather than exposing Active
Storage routes directly.

Suggested routes:

```text
GET /api/v1/telegram_conversations/:conversation_id/messages/:message_id/media
GET /api/v1/telegram_conversations/:conversation_id/messages/:message_id/preview_frames/:id
```

Controller scoping:

```ruby
subscription = current_api_agent.telegram_subscriptions.find(params[:conversation_id])
message = subscription.telegram_messages.find(params[:message_id])
```

For the original, require `message.media.attached?`. For a frame, find it
through that message's `preview_frames_attachments` association. This makes a
different Resident's IDs resolve as not found rather than relying on a manual
authorization branch.

Return a redirect to a short-lived Active Storage URL using the same five-minute
pattern as `Api::V1::AttachmentsController`.

Extend `TelegramMessage#transcript_json` with:

```json
{
  "media": {
    "kind": "video",
    "status": "ready",
    "caption": "Look at this",
    "transcription": "Machine-generated transcript",
    "metadata": {},
    "original": {
      "filename": "telegram-video-123.mp4",
      "content_type": "video/mp4",
      "byte_size": 12345,
      "download_path": "..."
    },
    "preview_frames": [
      {
        "timestamp_seconds": 3.5,
        "content_type": "image/jpeg",
        "download_path": "..."
      }
    ]
  }
}
```

Omit `media` for text-only messages. Never return Telegram's `file_id`,
`file_path`, bot token, or raw S3 object URL.

## Resident Trigger and Transcript

Update `ExternalAgentTelegramRequest` to format each Telegram message through
one model method rather than interpolating `message.text` everywhere.

For media, the full and delta prompts should include:

- sender and thread identity;
- explicit media kind and preparation status;
- typed caption, if any;
- machine transcription, clearly labelled;
- safe metadata;
- authenticated download paths;
- exact `curl` examples;
- for photos and preview frames, an instruction to download and inspect with the
  image tool;
- the existing Telegram reply command.

Add equivalent structured media information to `trigger_payload`, but only as
metadata and authenticated application paths. The hosted shim currently ignores
channel metadata and invokes Chaos with text, so the prompt remains the
operative delivery mechanism.

Do not add base64 images or signed S3 URLs to `request`, `request_delta`, or
`trigger_payload`. That would enlarge logs, interaction records, prompt-cache
inputs, and secret-bearing surfaces unnecessarily.

### Optional Later Enhancement: Native Image Trigger Items

Chaos supports structured local images, but the hosted trigger shim currently
accepts a text prompt and runs:

```text
chaos exec ... -
```

A later enhancement could:

1. let the shim receive authenticated media descriptors;
2. download images into an invocation-scoped directory;
3. invoke Chaos with structured user-input items;
4. delete files after the turn.

Do not block the first version on this. Resident-directed authenticated download
plus `view_image` uses the current boundaries and is easier to audit.

## User-visible Failure Behavior

Telegram should receive a brief response when souls.house cannot accept media:

- unsupported kind: no response in the first version, unless we decide to
  advertise supported formats;
- too large: explain the initial size limit and suggest sending a smaller file;
- invalid or mismatched file: explain that the upload could not be read;
- temporary Telegram download failure: retry silently first, then send a
  generic failure message after retries are exhausted;
- oversized video: suggest trimming or compressing it before resending, since
  the standard Bot API cannot download files above the initial 20 MB limit;
- transcription failure: do not message the sender as if the whole upload
  failed—the Resident still receives the recording;
- Resident offline: retain the prepared Telegram message exactly as text
  messages are retained today.

User-facing errors must not contain upstream response bodies, storage keys,
paths, or credentials.

## Privacy, Security, and Retention

- Keep every original and derived file private in Active Storage.
- Authorize downloads through the current Resident API key and association
  scoping.
- Use short-lived storage redirects.
- Stream downloads with hard byte limits.
- Detect MIME type from content.
- Construct `ffmpeg`/`ffprobe` calls as argument arrays.
- Bound media processing time, frame count, dimensions, and captured output.
- Never log Telegram file-download URLs.
- Filter any new sensitive job arguments or parameters from logging if needed.
- Purge media when its `TelegramMessage` or subscription is destroyed through
  normal Active Storage lifecycle behavior.
- Do not introduce a background retention purge in this change. Decide broader
  Telegram-history retention as a separate product/privacy policy.

## Implementation Sequence

### Phase 1 — Shared media foundation and photos

- [ ] Add media columns to `telegram_messages`.
- [ ] Add `wake_enqueued_at` and implement at-least-once ready-to-wake handoff.
- [ ] Add original and preview Active Storage associations.
- [ ] Add model validations and normalized transcript representation.
- [ ] Teach `ProcessTelegramUpdateJob` to recognize photos.
- [ ] Add bounded Telegram file download methods.
- [ ] Add webhook-size preflight and permanent/transient Telegram media errors.
- [ ] Add `PrepareTelegramMediaJob`.
- [ ] Add authenticated original/frame API routes and controllers.
- [ ] Add media metadata to Telegram conversation JSON.
- [ ] Add media-aware Resident prompt formatting.
- [ ] Verify Wing can send a photo, Wing can download it, inspect it, and reply.

This phase establishes the complete security and delivery path before adding
external transcription or video subprocesses.

### Phase 2 — Voice

- [ ] Recognize Telegram voice messages.
- [ ] Reuse `ElevenLabsStt` against the downloaded original.
- [ ] Preserve and label transcription provenance.
- [ ] Preserve voice captions and distinguish silence from STT failure.
- [ ] Make transcription failure non-fatal.
- [ ] Verify Wing receives both a transcript and authenticated original.

### Phase 3 — Video

- [ ] Recognize Telegram videos.
- [ ] Implement bounded `TelegramVideoPreview`.
- [ ] Extract metadata and representative frames.
- [ ] Extract/transcribe audio when present.
- [ ] Attach ordered preview frames once, as the final retry-safe video step.
- [ ] Expose ordered preview-frame paths.
- [ ] Verify Wing can inspect frames, read the transcript, fetch the original,
      and reply without claiming direct full-video vision.

### Phase 4 — Operational hardening

- [ ] Review logs for bot tokens, file paths, signed URLs, and transcript leaks.
- [ ] Confirm retry behavior with interrupted downloads and STT failures.
- [ ] Confirm duplicate webhook delivery produces one message, one attachment
      set, and no lost Resident wake.
- [ ] Confirm a simulated crash before and after enqueue follows the documented
      at-least-once behavior.
- [ ] Confirm cross-Resident media IDs return not found.
- [ ] Confirm large files stop streaming at the application limit.
- [ ] Confirm removal of a Telegram message purges its blobs.
- [ ] Deploy each phase independently and observe queue time, storage growth,
      STT latency, and trigger success before enabling the next phase.

## Test Plan

Follow the repository policy: Rails/Minitest for the behavior, VCR for external
Telegram and ElevenLabs calls, and real `ffmpeg` against tiny checked-in media
fixtures. Do not write tests whose setup directly supplies the processed result
they claim the lifecycle produced.

### `ProcessTelegramUpdateJob`

- Existing text and `/start` behavior remains unchanged.
- Photo update creates one pending media message and preparation job.
- Voice update creates one pending media message and preparation job.
- Video update creates one pending media message and preparation job.
- Caption is preserved separately from generated text.
- Unsupported media is ignored.
- Non-private media is ignored.
- Unsubscribed senders cannot create media records.
- Duplicate Telegram message ID creates one record and one preparation job.
- Oversize webhook metadata fails fast without calling `getFile`.

### `PrepareTelegramMediaJob`

- Downloads and attaches a valid photo.
- Rejects oversized content while streaming.
- Maps Telegram's pre-stream `file is too big` response to a permanent size
  failure without retry.
- Rejects MIME/type mismatch.
- Retries a transient Telegram failure.
- Does not duplicate blobs or frames during ordinary retries.
- Repairs a ready message with no `wake_enqueued_at`.
- Tolerates a duplicate wake at the enqueue/stamp crash boundary rather than
  losing the wake.
- Transitions pending to ready before triggering the Resident.
- Permanent failure records a safe category and does not trigger the Resident.
- Voice transcription success stores transcript and keeps original.
- Voice transcription failure keeps original and still reaches ready.
- Empty successful voice transcription remains absent rather than failed.
- STT receives the detected filename and content type.
- Voice captions are preserved in pending and ready normalized text.
- Video preprocessing attaches bounded, ordered frames.
- Video retry cannot append duplicate preview frames.
- Video without audio does not attempt transcription.
- Video frame failure retains the original and exposes honest status.

### `TelegramMessage`

- Validates known media kinds and states.
- Rebuilds normalized text correctly for every kind/status combination.
- `transcript_json` omits media for text messages.
- `transcript_json` distinguishes caption from machine transcription.
- API metadata contains authenticated application paths, not external URLs.

### Resident API

- Owning Resident can download original media.
- Owning Resident can download its own preview frame.
- Another Resident receives not found.
- Account API keys without a current Resident cannot access Resident Telegram
  media.
- Missing attachment returns not found.
- Download redirect expires through the existing short-lived URL mechanism.

### `ExternalAgentTelegramRequest`

- Full prompt includes photo metadata and safe download instructions.
- Delta prompt includes only the newly prepared media message.
- Voice transcription is labelled as machine-generated.
- Video frames are listed in timestamp order.
- Prompt and trigger payload do not include bot token, Telegram file URL, S3
  URL, or file bytes.
- Text-only prompt behavior remains unchanged.
- Persistent-session busy retry remains unchanged.

### Video integration fixture

Use a tiny deterministic video fixture containing:

- a known duration;
- changing visual frames;
- a short audio track.

Run real `ffprobe`/`ffmpeg` in the test environment and assert:

- metadata is derived from the file;
- no more than the configured number of frames is emitted;
- frames are valid images;
- tempfiles are cleaned up.

## Acceptance Criteria

The feature is complete when all of these are true:

1. A subscribed sender can send Wing a photo without any accompanying text.
2. One durable Telegram message and one private original attachment are stored.
3. Wing is woken only after the original is available.
4. Wing can fetch and inspect the image using the authenticated path in the
   prompt.
5. A voice note produces a clearly labelled transcription while preserving the
   original recording.
6. A transcription failure still gives Wing access to the recording.
7. A video produces a private original, bounded frames, safe metadata, and an
   audio transcription when possible.
8. Wing can distinguish typed caption, generated transcription, and system
   placeholders.
9. Duplicate webhook delivery cannot duplicate storage or preparation work;
   the cross-database ready-to-wake edge is deliberately at-least-once, so a
   rare crash-boundary duplicate wake is acceptable but a lost wake is not.
10. Another Resident cannot access Wing's Telegram media.
11. No bot token, Telegram download URL, signed S3 URL, or media bytes appear in
    trigger payloads, interaction records, or normal application logs.
12. Existing Telegram text messages and replies continue to work unchanged.
13. Oversized media is rejected promptly as a permanent size failure rather
    than retried as a transient download error.
14. Retrying video preparation cannot append or reorder preview frames.

## Verification Note: Hosted Shim Contract

The checked-out runtime/shim source may drift behind the deployed Resident
runtime. During Phase 1 end-to-end verification, inspect the actual deployed
trigger contract and observed request handling rather than treating a
neighboring repository's `trigger_shim.py` field names as authoritative.

## Rollout and Estimate

Ship behind the natural supported-kind boundary rather than a site-wide feature
flag:

1. deploy schema and photo path;
2. verify with Wing in production;
3. enable voice recognition and observe STT behavior;
4. enable video recognition after frame extraction is proven against production
   storage and queue constraints.

Expected focused implementation effort:

- shared foundation plus photos: 1–2 days;
- voice: approximately 1 day;
- useful video preprocessing: 1–2 days;
- hardening, production verification, and edge-case repair: approximately 1
  day.

Total: approximately 3–5 focused working days, with photos and voice able to
ship before video.
