# Proposals — not implemented architecture

This small area separates current discussion from the maintained implementation
guides. A proposal needs an explicit status; neither its presence nor its age
means it has shipped. Move settled behaviour into the relevant reference guide.

- [House default-model selection, Lume, 2026-09-30](2026-09-30-house-model-selection-from-lume.md)
  — research and recommendation; its “Before it ships” section remains a decision/
  implementation gate, not a change made by the documentation cleanup.

Earlier plans and requirements are retained in [the historical shelf](../.bak/README.md).
That move does not cancel unfinished work. Native-client work on other branches
must be reconciled with `master`; [API boundaries](../api.md) records the currently
implemented baseline rather than copying an unmerged design into the live guides.

For structured feature planning, place new requirement families under
`docs/proposals/requirements/` and iterations/reviews under `docs/proposals/plans/`
(create them when needed). The architecture resolver can still read archived
families, but new work must never be written into `.bak`.

## Work-resident planning (2026-10-01)

These are planning documents, not implemented capabilities. Only project 1 is an
active priority; projects 2 and 3 are parked until it is complete and resumed.

1. [Work residents and bounded delegation](plans/work-residents/01-work-resident-delegation.md)
   — trusted tool-using helpers under the existing container boundary; isolation
   hardening is deferred by Daniel’s explicit risk acceptance.
2. [Room presence/work switching](plans/work-residents/02-room-presence-work-switching.md)
   — parked; not a dependency of project 1.
3. [GitHub work-resident onboarding](plans/work-residents/03-github-work-resident-onboarding.md)
   — parked; reuses project 1's boundary when resumed.
