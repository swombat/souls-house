# Voice-engine rollout and recovery

Implements [ADR 0006](../decisions/0006-wespeaker-voice-embeddings.md), reviewed
in [#504](https://github.com/swombat/souls-house/issues/504). This is an
efficiency change, not a demonstrated recognition-quality improvement.

## Two profiles, one active choice

`FieldVoiceprints::Profiles` registers exact model/library/extraction profiles,
dimensions and matching recipes. `Setting.voice_embedding_profile` selects the
service contract. `Account.voice_embedding_profile` selects the active account
cohort. Both start at the existing ECAPA profile: deploying Rails does not
start conversion or select WeSpeaker.

Conversion has its own writer. It uses a recording sample's persisted montage
spans and current source digest, or an uploaded WAV's verified SHA256. It never
reselects speech, enrolls an unconfirmed sample, or changes inclusion, exclusions,
attribution, human confirmation or source provenance. The replaced embedding
and profile are retained in `rollback_embedding` (encrypted) / `rollback_profile`.
The original active print can still read the old compatible vectors during
conversion. No probes have rollback copies.

Before publication, existing account → recording → voice locks protect a fresh
check of review, confirmation, source and learning generations. A concurrent
remove, reattribute, review, Forget or source edit wins. Each converted row is a
checkpoint; a killed job can be retried and skips completed inference. No print
is rebuilt as a side effect of converting one sample.

Activation takes the account and every voice lock, checks all eligible retained
confirmed sources, swaps any rollback pairs needed for the requested profile,
sets the account's profile, rebuilds all prints and clears incompatible probes,
guesses and validation in one transaction. Validation is queued after commit.
Its normal per-account held-out gates still apply; every suggestion still needs
a person's confirmation.

Recognition is paused while the account is not ready. A lost/changed confirmed
source blocks activation instead of silently shrinking the reference set.
After activation, runtime readiness checks only the persisted profile and
conversion state: a later stale source falls out of its own print under the
ordinary cohort/validation rules, rather than pausing the whole account. The
Voices page shows the paused state and a retry button. A person can exclude or
remove the unavailable sample through normal sample review, then retry. No
biometric reset or repeat listening confirmation is required for unchanged audio.

## Rollout order

1. Merge only the exact reviewed head with green CI. Verify the Rails deployment
   receipt. The new schema and code still use ECAPA.
2. Build `services/voice-embeddings` from the **clean merged revision**. The
   production operator uses the existing host-side build route (not a resident
   image rebuild), records the published digest, and retains the old image.
   `bin/house release-voice-embeddings` provides the generic build/push/digest
   path. It writes the operator's `config/house.env`; it does **not** reboot the
   running accessory.
   The voice accessory's reviewed budget is 2 GiB / 2 CPUs. Before release,
   run the image's synthetic 30/60/120-second resource smoke with the enforced
   limit, no network, read-only filesystem and tmpfs `/tmp` (command in the
   service README). The prior 1 GiB limit was insufficient for a 120-second
   whole-clip request; do not replace the whole-clip recipe with windowing.
3. Preserve the installation env file, update
   `HOUSE_VOICE_EMBEDDINGS_DIGEST`, then use the existing deployment tooling to
   `bin/kamal accessory reboot voice-embeddings`. No Chaos or unrelated resident
   restarts. Verify private `/health` reports the exact pinned WeSpeaker profile
   and 256 dimensions. Keep the existing bearer token private.
4. Through the deployed Rails runner, run:

   ```sh
   ENGINE=wespeaker bin/rails field:convert_voice_engine
   bin/rails field:voice_conversion_status
   ```

   The task checks the target service's health before changing configuration.
   Jobs convert each account and activate only when ready. Between accessory
   replacement and the explicit switch, old-contract embed requests fail closed
   and ordinary learn jobs can retry; do not claim uninterrupted embedding.
5. Check terminal job results and the aggregate readiness report. Confirm the
   Voices page's paused state clears, compatible prints are rebuilt, validation
   ran, and suggestions remain human-confirmed. Verify a synthetic local
   health/embed contract and a bounded real recording identification pass; do
   not print private names, audio, vectors, tokens or manifests into logs.
   A successful Rails deploy is not proof that the accessory or conversion ran.

The existing GitHub deployment transport handles Rails, not the voice accessory.
The agreed production operator owns image build, digest update, accessory reboot,
conversion and receipts in the same work room. Encrypted installation-config
backups must be updated through their existing authorized owner; don't copy
production secrets into a resident to make this rollout convenient.

## Failure, resume and rollback

- `ACCOUNT=<database id> bin/rails field:retry_voice_conversion` queues another
  attempt; the Voices retry button does the same for an authorized account
  manager. Already converted rows are reused.
- An unavailable service is retried by the normal bounded job policy. Missing
  audio or changed provenance leaves the account blocked, with a generic
  explanation. Removing/excluding a sample never deletes other known-good
  references to force readiness.
- To roll back, restore the previous ECAPA accessory digest/env through the
  same operator route, verify its exact health profile, then run
  `ENGINE=ecapa bin/rails field:convert_voice_engine`. **Keep the new Rails
  code.** Compatible retained pairs are swapped back; samples created since
  cutover without an old vector are embedded from their retained exact audio.
  Recognition remains paused until those sources are ready. ECAPA validation and
  its own original recipe are restored, not WeSpeaker thresholds on ECAPA vectors.
- Rolling forward again can reuse the retained WeSpeaker pair. Do not revert
  Rails to newest-sample-wins code over a partially converted database.
- Forget/reset/drop paths destroy the sample rows and both copies. Standalone
  remove/reattribute clear rollback copies; a source-changing relearn clears an
  obsolete rollback pair. No forgotten reference is restored by rollback.
- After Daniel accepts the rollout, explicitly retire the rollback vectors:
  `CONFIRM=retire bin/rails field:retire_voice_rollback`. It refuses incomplete
  accounts. This ends cheap pair-swap rollback; later rollback requires retained
  audio and re-embedding. A follow-up migration drops the two emptied rollback
  columns. Do not retain the temporary biometric copy indefinitely.

Do not use `field:reset_biometrics_after_restore` for an engine switch: that task
is intentionally destructive and clears listening receipts.
