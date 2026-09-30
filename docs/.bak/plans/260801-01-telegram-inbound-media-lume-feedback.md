# Feedback: 260801-01-telegram-inbound-media

Reviewer: Lume, 2026-08-08. Every factual claim in the plan was checked against the
actual code (helix_kit + chaos-agent repos), not taken on trust. Verdict up front:
**this is a strong plan — right boundaries, right non-goals, honest about provenance
and failure states. It is ready for Mira after three specific fixes, all in the
"Prepare Media Asynchronously" / download areas.** Nothing structural needs to change.

## Verified claims (all confirmed against code)

- Text-only guard quote is exact (`process_telegram_update_job.rb:10-11`). ✓
- Existing pipeline path (webhook → job → message → trigger → shim) matches. ✓
- `ffmpeg` is in the Rails production image (Dockerfile:59); the hosted Resident
  image (chaos-agent Dockerfile) has `curl` but no ffmpeg. Both claims true. ✓
- The trigger shim reads only a text prompt (`trigger_shim.py:74`) — channel
  metadata is indeed ignored, so "prompt is the operative delivery mechanism" holds. ✓
- `ElevenLabsStt.transcribe(audio_file)` interface matches the planned usage. ✓
- `Api::V1::AttachmentsController` uses the 5-minute redirect TTL as described. ✓
- `HELIXKIT_APP_URL` / `HELIXKIT_BEARER_TOKEN` are the real env-var names, and the
  exact curl pattern in the plan already exists in production prompt text
  (`external_agent_response_request.rb:211`) — so the download instructions are a
  proven pattern, including the curl-redirect-to-S3 hop (curl ≥7.58 drops the
  Authorization header on cross-host redirect, so the signed S3 URL is not
  contaminated; this is already working in production for chat attachments). ✓
- Schema: `text` is `null: false`; unique index on
  `(telegram_subscription_id, telegram_message_id)` exists — the placeholder-text
  and duplicate-guard strategies are sound. ✓
- `ObfuscatesId.find` decodes obfuscated params, so the proposed controller scoping
  works as written. ✓
- `Message::Attachable` really is chat-specific (variants, docx text extraction,
  50MB chat limit) — skipping it is correct. ✓
- `TelegramConversationsController` already gates on agent API keys — the planned
  media controller inherits the right pattern. ✓
- Solid Queue argument claim: true that args stay inside souls.house, **but see
  issue 1 — the queue is a *separate database*** (`database.yml`:
  `helix_kit_*_queue`; `production.rb:54`).

## Issue 1 (must fix): the ready→trigger crash window loses wakes

Plan, "Prepare Media Asynchronously":

> 1. Return if the message is already `ready`. … 5. Set `media_status: "ready"` …
> 6. Enqueue `TelegramAgentTriggerJob`.

If the job crashes (or the worker is killed on deploy) between steps 5 and 6, the
retry hits the step-1 guard, returns, and the Resident wake is **silently lost** —
the media is prepared, Daniel thinks it was delivered, Wing never hears about it.
The plan's own line "only enqueue the Resident trigger on the transition from
non-ready to ready" *creates* this window as written.

And the obvious fix — wrap the status update and the enqueue in one transaction —
**does not work here**, because Solid Queue runs on a separate `_queue` database
(`config/database.yml`, `production.rb:54: connects_to = { database: { writing: :queue } }`).
Cross-database, there is no atomicity to lean on.

Recommendation: make the edge idempotent instead of exactly-once. Add a
`wake_enqueued_at` timestamp (or a `notified` value in `media_status`'s
state list) to `telegram_messages`:

- step 1 becomes: return if `ready` **and** `wake_enqueued_at` present;
- if `ready` but `wake_enqueued_at` nil → enqueue trigger, stamp, return;
- normal path: prepare → set ready → enqueue → stamp.

Worst case is a rare duplicate wake (tolerable: the 409/`SessionBusy` retry in
`TelegramAgentTriggerJob` already serializes the session), never a lost one.
Pick at-least-once explicitly; the plan currently implies exactly-once, which the
infrastructure cannot provide.

## Issue 2 (must fix): the Bot API's 20MB `getFile` ceiling changes the failure path for video

The plan treats "too large" as something caught by streaming with a byte cap.
For videos that will rarely be the mechanism: Telegram's Bot API refuses
`getFile` outright for files over 20MB (HTTP 400, "file is too big") — the
stream never starts. And a 30-second phone video at 1080p is typically
25–35MB, so **this is the common case for video, not an edge case**.

Two consequences the plan should absorb:

1. **Error taxonomy in `telegram_file_info`.** "Reject missing or unsuccessful
   results with `TelegramError`" lumps a permanent "file is too big" together
   with transient network failures. The bounded `retry_on` policy would then
   retry a permanent condition until exhaustion and send the *generic* failure
   message instead of the *size* message. Split `TelegramError` into
   permanent/transient (or carry a `retryable?` flag) and route "too big"
   straight to the failed/size-explanation path.

2. **Preflight on webhook metadata.** Telegram's incoming `photo`/`voice`/`video`
   objects carry an optional `file_size`. Check it in `ProcessTelegramUpdateJob`
   (or at the top of the prepare job) and fail fast with the size message —
   no `getFile` call, no retry cycle, and the sender hears back in seconds.
   Keep the streaming byte cap as defense in depth, as planned.

Also worth one sentence in the user-facing copy: for video, "send a smaller
file" should suggest trimming/compressing, since most phone videos will trip this.

## Issue 3 (must fix): `preview_frames` re-attachment is not idempotent by default

`has_many_attached` **appends** on every `attach` call. The plan requires
"Attachment and processing steps must be idempotent so retries do not create
duplicate blobs, frames…" and tests for it — but never states the mechanism,
and the naïve implementation fails the test: a transient STT failure *after*
frame attachment raises, the retry re-extracts, and the message ends up with
12 frames. Specify one of:

- purge any existing `preview_frames` at the top of video preparation
  (idempotent-by-reset), or
- attach all frames in a single `attach` call as the *last* video step,
  ordered, after transcription has succeeded or been marked failed.

(`has_one_attached :media` is fine as-is — replacement purges the prior blob.)
The second option also fixes frame *ordering* on retry: "attach frames in
timestamp order" relies on insertion order, which a partial retry scrambles.

## Minor points (fix in passing, none blocking)

1. **`ElevenLabsStt` returns `nil` on an empty-but-successful transcription**
   (`text.presence`, `eleven_labs_stt.rb:55`). A silent voice note transcribes
   to nil with HTTP 200. Decide explicitly: nil → `[Voice message]`
   placeholder with transcription absent, *not* `transcription_status: "failed"`.
2. **The STT wrapper must supply real filename/content_type.** The class's
   defaults are `audio.webm` (`filename_for`/`content_type_for`); a bare
   `Tempfile` of an OGG/Opus voice note would be mislabelled. The plan's
   "upload-compatible wrapper" is right — make the requirement explicit:
   wrapper responds to `original_filename` and `content_type` with detected
   values.
3. **Voice messages can carry captions** (Bot API allows it, even though
   official clients don't expose it). The `text`-rebuild rules for voice omit
   caption; either include it (mirror the video rule) or state that
   voice captions are deliberately dropped.
4. **Photo has no pending placeholder** in the text-rebuild list (voice and
   video do). A captionless photo pending preparation gets `[Photo]`, which
   reads as ready. Harmless — the window is seconds — but add
   `[Photo — processing]` for symmetry, or note the asymmetry is deliberate.
5. **Shim drift note for the implementer:** the chaos-agent repo's
   `trigger_shim.py` reads `payload["prompt"]` while `ChaosTriggerClient`
   sends `request`/`request_delta` — the deployed shim is evidently newer
   than the repo copy. Nothing in the plan depends on this, but Mira should
   trust the deployed contract, not the repo shim, when verifying Phase 1
   end-to-end.

## Things I checked and deliberately did not flag

- Enqueuing `TelegramAgentTriggerJob` from the prepare job without re-checking
  agent eligibility is safe — the trigger job re-checks
  (`telegram_agent_trigger_job.rb:10`).
- Purge-on-destroy works through the existing `dependent: :destroy` chain plus
  Active Storage's default `purge_later`; no extra work needed, as the plan says.
- Raw integer IDs for frame attachments (vs obfuscated message IDs) match the
  existing `AttachmentsController` pattern — consistent, fine.
- The broad voice MIME allowlist (M4A/WAV/MPEG for a channel that sends
  OGG/Opus) is harmless robustness, not a hole.
- Silence toward unsupported media kinds is a stated product choice with an
  explicit revisit hook. Fine for v1.

## Verdict

Ready for Mira once issues 1–3 are folded in — all three are localized to
`PrepareTelegramMediaJob` / `telegram_file_info` and none disturb the plan's
architecture, phasing, or API surface. The phase ordering (photos establish the
full security path first), the provenance discipline (caption vs transcription
vs placeholder), and the refusal to put bytes or secrets in trigger payloads
are exactly right. The estimate (3–5 focused days) is credible.
