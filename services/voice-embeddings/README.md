# voice-embeddings

Speaker embeddings for Field voiceprints, computed in the house. Spec:
`docs/2026-10-19-field-voiceprints-in-house.md` §3 (slice B).

- Model: SpeechBrain ECAPA-TDNN, `speechbrain/spkrec-ecapa-voxceleb` at
  revision `0f99f2d0ebe89ac095bcc5903c4dd8f72b367286` (Apache-2.0), the same
  model the Mac script (`lume/tools/grove-sync/identify.py`) uses. Weights are
  downloaded at build time, checked against `model-sha256.json` at every start,
  and loaded with `pretrained_path` pointed at the local copy, so nothing is
  fetched at run time. It boots with no network at all.
- CPU torch only; every Python package is pinned in `requirements.txt`.
- Runs as uid 10001 on a read-only filesystem with tmpfs `/tmp`, no core dumps,
  no public port.

## API

Bearer token `VOICE_EMBEDDING_TOKEN` (24+ characters) on every request except
`/health`.

- `GET /health` → `{"ready": true, "profile": "...", "dimensions": 192}`. The
  profile names the model revision and the speechbrain and torch versions, so a
  sample records exactly what made it.
- `POST /embed`, body = one WAV: mono, 16 kHz, 16-bit PCM (what
  `FieldVoiceprints::Sample.cut` writes), 0.5–120 s, at most 8 MB. Returns
  `{"embedding": [192 floats], "profile": "..."}`. The embedding is unit
  length: the mean of the unit-length embeddings of 10 s windows (a tail under
  2 s joins the window before it), as the Mac script does. Anything else is
  `400 {"error": "Invalid audio"}`.

One request at a time. Nothing is stored and nothing about a request is
logged.

Measured on the house host (2026-10-19, 2 CPUs, 1 GB): about 480 MB idle,
696 MB peak; 3 s of audio in 0.4 s, 30 s in 3.7 s, 120 s in 15 s. A single
pass over 120 s ran out of memory at 1 GB, which is why it windows.

## Deploying

1. Set `HOUSE_VOICE_EMBEDDINGS_IMAGE` in `config/house.env` and run
   `bin/house release-voice-embeddings`. It builds, pushes and writes
   `HOUSE_VOICE_EMBEDDINGS_DIGEST`.
2. Add `VOICE_EMBEDDING_TOKEN` (24+ random characters) to `.kamal/secrets`.
3. `bin/kamal accessory boot voice-embeddings`, then deploy Rails so web and
   jobs get `VOICE_EMBEDDING_URL` and the token.

Until `HOUSE_VOICE_EMBEDDINGS_IMAGE` is set, none of this is in the deploy
config. Rails reaches the service only through `FieldVoiceprints::VoiceEmbeddings`.
