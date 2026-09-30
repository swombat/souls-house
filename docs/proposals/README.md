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
