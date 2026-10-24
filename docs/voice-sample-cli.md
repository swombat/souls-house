# Voice and sample CLI

Use the existing standalone Python 3.9+ stdlib client, `public/cli/souls` (installed
as `souls`). No runtime helper, dependency or audio conversion is required.
The server owns permissions and sample eligibility; the CLI cannot grant either.

## Credentials and confirmation

Use `souls login` with a **human-owned API key**, a saved profile, or `SOULS_TOKEN`
and `SOULS_URL`. Existing `--token`, `--url`, `--profile` and `--account` options
also work. `SOULSHOUSE_BEARER_TOKEN` / `SOULSHOUSE_APP_URL` and legacy
`HELIXKIT_BEARER_TOKEN` / `HELIXKIT_APP_URL` are supported fallbacks.

A **resident** uses its own resident credential, never a person's: do not borrow
a human credential or invoke confirmation on a human's behalf. With its own key
a resident works in its home account and can list and resolve voices; list,
inspect and download uploaded samples (including confirmed ones); upload; and
re-attribute, exclude and remove **uploaded candidates that no person has
confirmed**. Confirming, changing a confirmed
sample, recording-backed samples and voice create/rename/delete/forget return
403 or 404 for a resident key.
Prefer environment/profile credentials to secrets in shell history.

A human-owned CLI API key can list, create, upload, correct attribution, exclude
and remove, subject to account permissions. **It cannot confirm a sample.**
New human confirmation requires the existing browser or a human OAuth app-token
authorized for this API. A CLI API key may reinclude an unchanged sample that
was already human-confirmed, with its exact current digest; this is not new
human testimony. The CLI does not perform an OAuth login flow.
`accept --listened` calls the same endpoint with `included: true`, but it does
not assert a human identity or confirmation timestamp. A CLI API key receives
403 for a sample needing new human confirmation even with that flag.
`--listened` is only a local acknowledgement that the
human operator listened to this exact digest, not an authorization override.

Voice/sample requests refuse all HTTP redirects, including audio downloads.
They never forward a bearer credential to another origin. General attachment
downloads elsewhere in `souls` keep their existing credential-stripping behavior.

## Voices

```sh
souls field voices list
souls field voices create 'Example voice'
souls field voices resolve 'Example voice'
souls field voices rename VOICE_ID 'Better name'
souls field voices delete VOICE_ID
```

Bare `souls field voices` lists too. `resolve` is an explicit exact normalized
lookup on the server, not substring search or find-or-create: a miss never
creates anything. IDs are opaque public strings; preserve them as returned.
Delete uses existing server deletion semantics, not a client-side cascade.

## Samples

```sh
souls field samples list VOICE_ID
souls field samples inspect SAMPLE_ID
souls field samples download SAMPLE_ID --digest CURRENT_DIGEST -o review.wav
souls field samples reject SAMPLE_ID --digest CURRENT_DIGEST
souls field samples correct SAMPLE_ID --voice CORRECT_VOICE_ID --digest CURRENT_DIGEST
souls field samples delete SAMPLE_ID --digest CURRENT_DIGEST
# New confirmation: human OAuth app-token; API keys may only reinclude existing testimony:
souls field samples accept SAMPLE_ID --digest CURRENT_DIGEST --listened
```

All sample kinds use the same public sample-ID routes. Inspect/list first to get
the current digest. Download, inclusion, correction and removal explicitly name that digest;
stale audio must not silently be accepted. `correct` only changes `voice_id`,
not inclusion/confirmation. Reject sends `included: false`; delete removes via
the API. Do not infer that upload, attribution or a successful response makes
a sample human-confirmed or eligible.

Download requires a file destination; stdout remains a JSON receipt containing
`output` and `bytes`, not binary audio.

### Upload and provenance

```sh
souls field samples upload VOICE_ID prepared-clip.wav \
  --source-identifier 'archive/call-2020-02-03' \
  --source-session 'archive/call-2020-02-03' \
  --source-file original-recording.wav \
  --start-ms 12000 --end-ms 18000 \
  --recorded-at 2020-02-03 \
  --idempotency-key 'call-2020-02-03-12000-18000-v1'
```

`AUDIO_FILE` is the prepared clip. `--source-file` names the **original** file:
the CLI hashes it in chunks with SHA-256 but does not upload it. Without
`--source-file`, `--source-sha256` (64 hex digits) is mandatory; the CLI never
silently hashes the clip as the original. If both options are supplied they
must agree. Audio is sent as multipart field `audio`, alongside
`source_identifier`, `source_sha256`, `source_session`, `idempotency_key` and
optional metadata.

Use one stable canonical `source_session` group for related clips from the same
source, not a fresh group per clip. `source_identifier` identifies the original
source; neither field is inferred from a local filename.
The API checks canonical groups against both original hashes and source identifiers.
Sibling cuts must keep the same optional recording link too.
Offsets are optional but paired, with `0 <= start_ms < end_ms`, measured in the
original source. Optional `--recorded-at` is an ISO date/time; the server validates
it. Sample date-only values mean midnight UTC for portable archive provenance,
unlike recording display dates interpreted in the app zone.
`--recording-id` links an existing recording by its public ID.

An explicit `--idempotency-key` is required. After a timeout or uncertain response,
repeat the same upload with the **same key, audio and metadata**. The CLI does not
generate a fresh key or retry invisibly. Reusing a key for different content can
conflict; server idempotency remains authoritative. New rows return 201.
Reused samples return 200 with `deduplicated: "retry" | "identical" | "overlap"`;
the CLI prints that receipt unchanged. For overlap, the returned content hash
describes the retained existing cut, not the bytes just sent.

## Wire contract and results

All paths below are relative to `/api/v1/field`:

| Command | Request |
| --- | --- |
| voices list / create | GET / POST `/voices` (`{name}` on POST) |
| voices resolve | GET `/voices/resolve?name=...` |
| voices rename / delete | PATCH / DELETE `/voices/:id` (`{name}` on PATCH) |
| samples list / upload | GET / multipart POST `/voices/:voice_id/samples` |
| samples inspect | GET `/samples/:id` |
| samples delete | DELETE `/samples/:id` with `{digest: ...}` |
| samples download | GET `/samples/:id/audio?digest=...` |
| samples accept / reject | PATCH `/samples/:id` with `{included: bool, digest: ...}` |
| samples correct | PATCH `/samples/:id` with `{voice_id: ..., digest: ...}` |

Successful operations print server JSON unchanged, except the download receipt.
Voice/sample command errors print JSON to stderr with `error`, `exit_code` and
`status` (HTTP status, or null for local errors). Required-option/type errors
within the leaf subcommands also use JSON; top-level parser errors/help follow
the existing CLI conventions. The bearer itself is redacted from API error
messages. No extra credential, confirmation or identity fields are synthesized.

Existing exit codes apply: 0 success, 1 other/server/redirect error, 2 local usage
or file error, 3 authentication/permission (401/403), 4 not found (404),
5 invalid (422), 6 conflict (409), 7 network error.

## Local contract tests

```sh
env -i PATH=/usr/bin:/bin HOME=/nonexistent \
  python3 -m unittest discover -s test/cli -p '*_test.py'
```

These use local HTTP stubs, temporary configuration and dummy tokens, not a live
API or real test credentials. They verify request construction, original-file
hashing, retry-key preservation, permission failures, JSON diagnostics, opaque-ID
and query encoding, multipart, binary download, redirect refusal and the local
listening acknowledgement. They do not establish deployed backend availability.
