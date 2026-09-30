# Mnemodyne production release — September 6, 2026

Daniel authorized integration, push and deployment at 08:31 CEST.

**Completed and verified at 09:32 CEST.** Rails web/jobs are running
`21bb000cf0b28458afd6860c69f7799b5331b42f`. All nine hosted residents are healthy
on the new runtime, with private vaults and managed BeforeTurn/Stop hooks.

## Completed production evidence

- Runtime amd64 image:
  `sha256:0bf892764bdbeeaf0c78d8dd677c57264b4028107b738f6c68234c7119e6bfef`,
  built from Chaos `f3bb63d6aec1ffdcab6330095701f3308c350199`.
  Actual binary: `chaos 47.3.0.1788678396`.
- Private embedding accessory is running the published manifest below;
  internal health and deployed `mnemodyne:check` report the expected profile
  and 384 dimensions. Public `/up` returns HTTP 200.
- Fresh pre-release full backup completed, including database artifact
  `souls_house_production_2026-09-06_06-51-24.sql.gz`.
- Deployed through normal Kamal, with `SOULSHOUSE_SKIP_AGENT_RECONCILE=1`
  holding fleet replacement until after the synthetic production canary.
  `log/mnemodyne-production-deploy.log` records successful web/jobs deployment.
- Production canary passed on the real amd64 runtime: installed hooks and guide,
  automatic first-vault provisioning, API/CPU embedding/recall, selected source
  use, and Stop's formation invitation. No provider credentials were injected
  and no model was invoked. Canary records/container/labelled volumes were
  removed; `log/mnemodyne-production-canary.log`.
- Reconciled resident IDs **1, 2, 3, 4, 7, 8, 9, 11, 12** through the supported
  runtime lifecycle after checking activity. Verified each actual image ID,
  installed hook bytes and configuration, guide, and authenticated memory API.
  All nine had empty private graphs at verification; no needs or memories were
  seeded. `log/mnemodyne-production-resident-rollout.log`.
- With residents idle, a post-release full backup created valid **paired graph
  checkpoints for all nine**, then database artifact
  `souls_house_production_2026-09-06_07-32-05.sql.gz`. These successful checkpoints
  satisfy their already-scheduled first-checkpoint jobs.
- Final verification: **9/9 healthy, 9/9 paired checkpoints, zero failed
  Mnemodyne jobs, zero synthetic canaries remaining**, plus a successful
  `ProbeJob.perform_now`. `log/mnemodyne-production-final-verification.log`.

The record below preserves the interruption and recovery history. It is not
the current deployment status.

## Integrated and published

- Integrated upstream `cabe01a` (admin runtime-session output) by rebasing the
  six reviewed commits. Pushed `681e1bc` to `origin/master` normally, without
  force. User-authored local review and routes whitespace remain untouched.
- Rechecked the integrated release: **2,189 Rails tests / 11,034 assertions,
  zero failures/errors/skips; 18 browser tests passed; real local image smoke
  1 test / 49 assertions passed**. Logs: `log/mnemodyne-release-{rails,browser,smoke}.log`.
- Built the embedding image natively on the production amd64 Docker host and
  published `dtenner/souls-house-mnemodyne-embeddings:681e1bc`.
  Independently inspected the published registry manifest:
  **`sha256:a27b4e9f1d24645c9bd21126f66119837054bad41c19102f1fc836db5006f08a`**.
  Use this value for `MNEMODYNE_EMBEDDING_IMAGE_DIGEST`.
- Existing deployment credentials were copied read-only from the primary
  checkout into ignored, mode-0600 files in instance 2. A new 64-character
  embedding bearer token was generated at
  `config/credentials/deployment/mnemodyne_embedding_token.key`; its value is
  not in logs or source control. Do not regenerate it when resuming this release.

## Production preflight and interruption — subsequently resolved

Production was running Rails `fffd2f433f8a4341872a26c377cc366d60176b94`.
All nine externally hosted residents were healthy and idle at preflight;
successful resident backups were recorded between 04:00:04 and 04:00:56 UTC
on September 6.

Preserved the old runtime as `helixkit-agent-runtime:pre-mnemodyne-20260906`,
image ID `sha256:be399fa9e2974c5606d4c33e8db413066a61c523fef69ea359d10a3d079ab078`.
The new runtime build uses the separate
`helixkit-agent-runtime-mnemodyne-candidate` repository, so it does not move
the residents' `latest` tag before verification.

That candidate build lost SSH during Rust compilation. Subsequent connections
to both `misc` and `95.217.118.47:12222` were refused. The cause is not established;
do not infer that the host rebooted, ran out of memory, or finished its build.
The attempted fresh pre-release full backup never started because SSH was
already unavailable. `https://souls.house/up` still returned HTTP 200 at
08:37 CEST.

**At that interruption, nothing had been deployed:** the embedding accessory,
Rails/migrations and resident container updates were still pending.
The runtime build command failed; remote state was inspected after SSH returned.

Daniel noted a possible SSH protection timer after the connection burst. This
remains a plausible explanation, not a confirmed diagnosis. Access returned
after a quiet interval. Remote operations then used release-local SSH connection
reuse (without changing global SSH configuration) and serialized builds.
The interrupted compile had not produced a candidate image; a fresh build
completed successfully. Added a Docker-context exclusion for deployment `.key`
files as a further safeguard; the application build used a clean Git clone.

## Recovery checklist — completed

1. Recheck resident activity, host resources and candidate-build state. Take a
   fresh `FullBackupJob.perform_now(fail_fast: true)` backup while idle.
2. Finish and verify the amd64 runtime candidate using the pinned Chaos source
   in `agent-runtime/chaos-ref`; retain the recorded rollback image.
3. Export the published digest above for every Kamal invocation. Boot and
   internally health-check the private embedding accessory.
4. Deploy the current pushed master with `SOULSHOUSE_SKIP_AGENT_RECONCILE=1`
   so the post-deploy hook does not replace the fleet ahead of a canary.
   The normal pre-deploy hook builds/tags the reviewed runtime.
5. Verify migrations, web/jobs health and `mnemodyne:check`. Exercise the live
   memory path with a synthetic canary, without writing invented memories into
   real residents' graphs.
6. Reconcile resident containers through the supported lifecycle, respecting
   active turns. Verify actual image identity, installed hooks/guide, empty
   vault provisioning and initial paired checkpoints; then record completion.

All work remains in instance 2. No other development instance was modified.
