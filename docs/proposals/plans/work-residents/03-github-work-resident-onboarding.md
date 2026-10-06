# 3. GitHub-hosted work-resident onboarding

Status: A bounded first slice was reprioritised by Daniel on 2026-10-06 in
qelBoJ / JBxwre; see [issue #177](https://github.com/swombat/souls-house/issues/177)
and the [onboarding guide](../../../features/github-resident-onboarding.md).
The broader capabilities below remain a proposal, not a claim of delivery.
Independent of project 2 unless later product choices introduce a real dependency.
Author: Mira, 2026-10-01. Source: qJlpyJ / JpkOEY.

## Goal

Let people such as Pepe and seuros provision a GitHub-hosted resident with approved
work capabilities and native delegation, without a Mira/Lume-specific deployment
recipe or an automatic change to ordinary residents.

## Contract

A versioned repository manifest requests a runtime entry point, supported model
profiles, delegation capability and required tools/services. The house displays
and validates these requests; an authorised owner approves effective grants.
Repository content is untrusted configuration, not permission. Git pushes cannot
increase model spend, secret access, network/tool privileges or delegation depth.

Reuse project 1’s delegation and lifecycle work, but decide the trust boundary
explicitly for broader hosting. Its initial shared-container risk acceptance for
Mira and Lume is not a blanket approval for other residents. The resident's
own identity/memory conventions remain theirs; this project does not impose Mira's
journals or a mandatory house memory stack. Record provenance for the repository
and pinned revision used at each launch.

## Plan when resumed

1. Inventory existing GitHub resident provisioning and identify only the missing
   work-capability pieces. Reuse it rather than create a second hosting product.
2. Specify and validate a small manifest schema with a working example; provide
   a capability diff and explicit owner approval for privilege increases.
3. Provision with pinned source, controlled build/install steps and no production
   runtime secrets exposed to repository build scripts. Apply least-privilege
   service grants and the tested helper isolation boundary.
4. Add preflight checks for supported harness features, models and authentication,
   finite resource limits, durable identity storage and workspace separation.
   Fail clearly when a required capability cannot be enforced.
5. Document update, rollback, revoke, export and removal paths. Existing sessions
   need an explicit policy for grant revocation; rotating/removing a config value
   does not recall copies of an already exposed credential.
6. Pilot with a consenting owner/resident pair, without accessing unrelated
   residents' credentials or private memories. Publish a reproducible guide.

## Acceptance

An owner can create an eligible resident from a documented repository, approve
bounded work access, and observe one safe attributed helper task. An update cannot
self-approve expanded grants. A malicious build cannot read runtime secrets. An
invalid manifest or missing isolation fails closed. Revocation stops further
privileged actions and leaves truthful task state. Rollback reaches a pinned
known-good revision without overwriting identity/user work. A standard relational
resident sees no new requirements.

## Deferred decisions

Hosting/pricing limits, permitted harnesses and trusted build images, repository
visibility and installation permissions, service-grant UX, storage/export policy,
and whether room switching is offered initially. Do not solve these in project 1.

Delivery requires reviewed mainline changes, documentation and an explicitly
authorised verified pilot—not merely a sample manifest or a successful build.

Related: [Project 1 — active priority](01-work-resident-delegation.md).
