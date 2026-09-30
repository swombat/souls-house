# Review: Agent image generation

**Reviewed:** `260725-01-agent-image-generation.md`  
**Date:** 2026-07-25  
**Verdict:** Keep the attachment seam; remove the HelixKit generation subsystem from v1.

## The central correction

The draft identifies the right boundary and then builds past it.

HelixKit's responsibility is:

> Accept files made by an agent and attach them to that agent's message.

It does not need to know how the file was made.

Chaos and the agent already have the capabilities needed to generate images:

- provider credentials are present in the hosted runtime;
- the agent can call OpenRouter or another provider itself;
- Chaos already saves completed native OpenAI image-generation results to a local
  file (`/tmp/<image_id>.png`) in
  `chaos/sys/kern/kern/src/stream_events_utils.rs`.

The Rails-like design is therefore a small, general message-attachment feature,
not an image-generation service inside HelixKit.

## Findings

### 1. [High] The recommended proxy is unnecessary product and infrastructure

Lines 45-60 make Option B canonical, which introduces:

- a generation endpoint;
- an OpenRouter HTTP client;
- a `GeneratedImage` model and migration;
- duplicated attachment variants;
- generation-specific authorization and error handling;
- long-running web requests;
- rate limiting and spend controls;
- orphan retention policy;
- another runtime helper;
- a new gallery data model.

None of that is required to put an image in a conversation. It duplicates work
the agent and Chaos can already do, while making HelixKit responsible for a
provider protocol that does not belong to its conversational domain.

**Recommendation:** make direct generation in the runtime the only v1 path.
HelixKit receives the resulting file through its existing message resource.

### 2. [High] Agent attachments do not currently render in the UI

The draft says the rendering requirement is already built, but
`MessageBubble.svelte` renders `message.files_json` only in the `role ===
'user'` branch (lines 93-99). The assistant branch has no attachment rendering.

Extending the API alone would store and serialize the image, but it would not
show on an agent message.

**Recommendation:** render the existing `FileAttachment` component in both
message branches. Ideally extract the repeated attachment list into one small
snippet/component rather than duplicate markup.

### 3. [High] Prefer one atomic multipart message request

The two-step `generate -> create blob -> attach signed blob id` flow creates
orphans, retention questions, cross-account authorization concerns, and extra
state transitions.

The browser message controller already demonstrates the Rails-native operation:

1. build the message;
2. attach `params[:files]`;
3. save once, allowing `Message::Attachable` validation to run.

The API controller should follow that same shape. This also supports screenshots,
charts, diagrams, edited images, and arbitrary agent-created files without
adding a new endpoint for each provenance.

**Recommendation:** v1 accepts `multipart/form-data` with:

- `content`
- `files[]`

Do not accept ActiveStorage signed blob ids in v1. Add them later only if a real
workflow requires pre-uploaded blobs, with explicit account ownership checks.

### 4. [High] `GeneratedImage` duplicates the real domain object

Once an image is posted, the durable object is the message attachment. A second
record creates two lifecycles and an awkward question: when the generated image
is attached later, who updates its optional `conversation` association?

The requested account gallery can be derived from existing records:

- ActiveStorage image attachments
- whose record is a `Message`
- whose message belongs to a chat in the account
- optionally restricted to messages with an `agent_id`

That query gives thumbnail, agent, date, and conversation without a migration.
The message content supplies the surrounding caption/context.

**Recommendation:** if the gallery is needed in v1, call it **Agent images** and
list image attachments on agent-authored messages. Do not promise that discarded
or never-posted generations are retained by HelixKit.

### 5. [Medium] The purported thin proxy is not actually transparent

The proposed request contains `input_image_ids`, but OpenRouter's provider API
accepts reference-image payloads rather than HelixKit record ids. HelixKit would
have to authorize each id, download/read each blob, encode it, translate the
request, and decide which kinds of records can be referenced.

That is already a meaningful generation abstraction, not a verbatim
passthrough. Editing would make the proxy grow further.

Removing the proxy removes this accidental API design problem.

### 6. [Medium] Synchronous generation would occupy Rails request capacity

A 10-120 second provider request is qualitatively different from a normal Rails
controller request. If HelixKit owns it, production concerns immediately include
server timeouts, worker occupancy, retries, client disconnects, idempotency, and
concurrency accounting.

Letting the agent perform the long-running call inside its Chaos turn keeps that
work in the runtime already designed to hold long agent operations.

### 7. [Medium] Image-only assistant messages need an explicit completion rule

`Message#completed?` currently considers an assistant message complete only when
`content.present?`. If the API permits an attachment with blank content, an
image-only message may retain incomplete/streaming semantics in parts of the UI.

Choose one:

- simplest v1: require nonblank `content` alongside every attachment; or
- support image-only messages and change completion to include
  `attachments.attached?`.

I prefer supporting image-only messages because it is natural for this feature,
but the behavior must be deliberate and tested.

### 8. [Medium] Return the ordinary serialized message

The API currently returns only `{id, content, created_at}`. After adding files,
return the normal message JSON (including `files_json`) rather than inventing a
second attachment response shape. That keeps the API aligned with the UI and
existing model serialization.

## Recommended v1

### R1 — Agent messages accept files

Extend `Api::V1::MessagesController#create` to accept multipart uploads:

```text
content=Here is the image
files[]=@/tmp/ig_123.png
```

Build the attributed message, attach files before save, save once, and return
the serialized message. Reuse `Message::Attachable` validation and variants.
Require at least content or one file.

### R2 — Agent messages render attachments

Render `files_json` for assistant messages with the existing
`FileAttachment -> ImageLightbox` path. Verify thumbnail, preview, and original
download.

### R3 — One ergonomic runtime command

Extend the existing helper rather than adding a generation helper:

```sh
printf '%s\n' 'Here is the image.' |
  helixkit-post-message CONVERSATION_ID --attach /tmp/ig_123.png
```

Allow repeated `--attach`. The helper sends multipart only when files are
present and preserves its current JSON request for text-only messages.

Generation remains ordinary agent work:

- native OpenAI image output saved by Chaos can be attached directly;
- OpenRouter/Nano Banana output can be written to a local file and attached;
- screenshots or images made by any future tool use the same command.

The HelixKit manual should explain the local-file-to-message flow, not prescribe
or wrap a provider API.

### R4 — Account image index, only if needed now

Add a read-only account page backed by agent-authored message image attachments.
No `GeneratedImage` model, generation metadata, billing integration, retention
job, or generation API.

If prompt/model/cost provenance later proves valuable, design it from observed
use rather than requiring every image source to pretend it came through one
HelixKit proxy.

## Suggested implementation footprint

Likely touched surfaces:

1. `app/controllers/api/v1/messages_controller.rb`
2. `app/frontend/lib/components/chat/MessageBubble.svelte`
3. `agent-runtime/helixkit-post-message`
4. `app/lib/agent_identity_exporter.rb`
5. focused controller/helper/component tests
6. optionally one account image-index controller/view

No new generation controller, provider client, model, migration, background
job, billing concept, or retention system.

## Answers to the draft's open questions

1. **Multipart vs signed blobs:** multipart only for v1.
2. **Auto-post:** neither; generation is outside HelixKit, posting is one atomic
   message request.
3. **Billing:** outside this feature. Provider usage remains provider/runtime
   usage.
4. **Retention:** normal message attachment lifecycle. HelixKit does not retain
   discarded local generations.
5. **Input images:** the agent downloads an existing attachment through the
   already-authenticated attachment endpoint and supplies it to its chosen
   generation/editing tool.
6. **Direct path documentation:** document the capability at the right level:
   generate or edit an image in the runtime, save it locally, attach it. Avoid a
   HelixKit-owned model list and detailed provider tutorial.

## Acceptance test that matters

From a hosted Chaos turn:

1. obtain or generate an image as a local file;
2. post an agent message with that file using `helixkit-post-message --attach`;
3. see the thumbnail on the agent's message;
4. open the preview and download the original;
5. trigger another agent and confirm its transcript contains the authenticated
   attachment download path;
6. optionally find the image in the account-level agent image index.

That proves the durable seam without building a second image platform inside
HelixKit.
