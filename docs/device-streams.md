# Device RR streams (first server slice)

This feature transports observations, not live agent attention or medical
interpretation. No ingest wakes an agent, sends a chat message or controls audio.
The Mac still records locally first. ECG, accelerometer data, private messages,
session annotations and derived findings are **not** accepted by `rr.v1`.

## Setup after deployment

1. Apply the migration and restart Rails through the normal deployment process.
2. The data subject selects the house account and opens **Account Services →
   Device integrations → Manage your device streams**
   (`/accounts/:account_id/device_streams`), then creates a named stream.
   It starts disabled. Lists, reader choices and all normal controls stay inside
   that account; the account name is shown throughout.
3. The subject explicitly selects human/agent readers and enables ingestion.
   Future account members are not automatically readers. The subject always has
   read/control access while a confirmed member.
4. Create a device credential on that page. Copy the one-time `shd_…` secret
   directly to the Mac, never to chat. Only its SHA-256 digest is retained.
5. Implement the bridge POST adapter below. The existing local-only recorder
   does not magically start uploading when the endpoint deploys.
6. With synthetic data first, check 201, identical retry 200, conflict 409,
   read access, revocation, session erasure and rejected late replay.

Only the subject controls readers, devices and deletion through the browser,
with standard session authentication and CSRF protection. An account admin or
an agent owned by the subject does not inherit these application permissions.
Infrastructure administrators can still access storage. If subject membership
becomes inactive, ingestion and reads stop; the subject's direct control URL
still permits revoke/erase. Account/user deletion also removes owned streams.
`/device_streams` is a separate personal recovery index across accounts, not a
creation or reader-management page. It retains subject-only revoke/erase controls
after membership loss without exposing the former account's resident roster.

## Append API

`POST /api/v1/streams/:stream_key/samples`

Use `Content-Type: application/json` and `Authorization: Bearer shd_…`.
Ordinary agent/human API keys are deliberately rejected here. Conversely device
credentials cannot read streams or authenticate against any other house API.

```json
{
  "schema": "rr.v1",
  "session_id": "dfd5a4f7-6a83-45eb-aaef-090c524bd607",
  "sequence": 0,
  "observed_at": "2026-09-25T20:00:00.000000Z",
  "rr_ms": [810.546875, 798.828125]
}
```

One batch is one RR-bearing Bluetooth notification. `observed_at` is Mac UTC
callback receipt time, not sensor beat time or upload time. Keep notification
order and RR precision: `ticks * 1000 / 1024`, without integer rounding.
Notifications without RR remain local; no empty batch. Persist UUID, sequence
and payload before uploading; retries must preserve the complete batch.

Session UUID is lowercase canonical form. Sequence is an integer from 0 through
2^53−1, unique per stream/session. New recordings use fresh session UUIDs.
Out-of-order delivery is accepted. Timestamps require an explicit timezone,
normalize to UTC microseconds, and may be at most five minutes ahead of server
time. Historical uploads are accepted and retained, but not returned by latest.

Limits: 16 KiB JSON body, 1–256 finite positive RR intervals per batch, at most
65535 Bluetooth ticks per interval, 600 newly accepted batches/minute/stream,
2,000,000 stored batches/stream, 1,000 session IDs/stream including tombstones,
five active credentials/stream. Capacity errors never silently evict data.
The application admission limit does not replace a reverse-proxy body limit.
Operators should configure a matching upstream limit.

201 new; 200 identical normalized retry; 409 changed reuse of sequence;
401 invalid/revoked/wrong-stream credential; 403 disabled/inactive membership;
410 erased stream/session when authenticated; 413 capacity/body limit;
422 invalid schema/data; 429 rolling-minute admission limit.
Revoked credentials get 401 even if their former stream was erased.
Retry only transport failures/5xx/429 with capped exponential backoff and jitter.
Pause and surface other failures; do not spin on revoked/erased streams.

## Read API

`GET /api/v1/streams/:stream_key/latest` uses a normal account-scoped API key
whose actual human or agent principal has an explicit grant. Agent credentials
do not inherit the permissions of the human who issued them.

Returns the newest 20-minute observation window (plus five minutes of tolerated
client clock lead), up to 1,200 batches in observation order, with session,
sequence, observed and server-received timestamps. `truncated` indicates the cap;
an empty window does not mean no historical data is stored. `server_time` and
`latest_received_at` support freshness checks; no completeness guarantee is made.
There is no historical download API in this first slice.

UTC deltas cannot reproduce monotonic integrity calculations. Keep monotonic
timing, disconnect/contact evidence, interval boundaries, algorithm version and
signed deficit diagnostics locally. A suspected gap is not proven transport
loss; `ok` is not proof of completeness.

## Erasure and retention

No automatic TTL: samples stay until subject erasure, account/user deletion or
an explicitly implemented future policy. The browser has per-session deletion,
including a UUID field for older/not-yet-uploaded sessions, and permanent bulk
erasure. Bulk erasure closes the stream and revokes all devices; create a new
stream to record again.

Per-session erasure deletes sample rows physically, keeping only a session UUID
and erasure timestamp tombstone. All appends, erasures and credential revocations
serialize on the stream row. An append committed before deletion is removed;
one ordered after it is rejected. Tombstones reject late retries indefinitely.
Credential revocation is checked again inside the append lock.

These operations do not erase local Mac files, prior downloads, derived
findings, logs made outside this application, PostgreSQL WAL or backups.
Before real upload the operator must state backup retention. Before restoring a
backup, reconcile subsequent erasures and revocations **before** making it
accessible or reopening ingestion. This slice does not automate that process.
Database row deletion is not a promise of forensic media erasure.

RR/timestamp request parameters and authorization headers are filtered from
application logs; do not enable proxy body/header logging. Responses use no-store.
Publication needs separate permission. Findings, if shared, need an author,
session ID, code version and delivery to the subject; this ingest endpoint
neither stores claims nor grants publication rights.

## Validation

Focused tests:

```sh
bin/rails test test/models/device_stream_test.rb \
  test/models/device_stream_concurrency_test.rb \
  test/controllers/device_streams_controller_test.rb \
  test/controllers/api/v1/streams_controller_test.rb
```

Use a separate instance database and synthetic fixtures. Never point these tests
at live device data or give a test bridge an agent credential.
