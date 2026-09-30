---
name: architecture
description: Review the final architecture or implementation plan for a requirements family in this repository. Use only when explicitly invoked as `$architecture <requirements-file-or-stem>` to compare the latest plan in `docs/proposals/plans` against the original requirement in `docs/proposals/requirements`, detect drift, missing coverage, scope creep, and architectural risks, and write a review artifact.
---

# Architecture Review

Use this skill to follow up on the repo's `.claude/commands/architecture.md` workflow. The job is to audit the latest plan output against the original requirements and capture the findings in a durable review file.

## Input

The user should invoke this skill as:

```text
$architecture <requirements-file-or-stem>
```

Accept these forms:

- `docs/proposals/requirements/YYMMDD-01-feature.md`
- `260301-01-search.md`
- `260301-01-search`

If the user does not provide a requirements identifier, ask for it before continuing.

Legacy input is read-only under `docs/.bak/{requirements,plans}`; the resolver
also accepts its original stems. Never write a new review or plan into `.bak`.
For a historical review, create the new artifact under `docs/proposals/plans/`.
To resume implementation of that family, first copy its requirement and selected
plan into the current proposal directories with provenance; the resolver keeps
current and archived plan families separate.

## Repo Conventions

- Requirements live in `docs/proposals/requirements/`.
- Plan iterations, DHH feedback, progress notes, and review artifacts live in `docs/proposals/plans/`.
- Files in the same plan family share the same numeric stem, such as `260301-01`.
- Main plan versions advance by letter: `a`, `b`, `c`, and so on.
- Supporting artifacts usually use suffixes such as `-dhh-feedback`, `-dhh-review`, `-implementation-review`, `-code-review`, `-progress`, or `-architecture-review`.

## Workflow

1. Resolve the requirement and plan files first.
   Run:

   ```bash
   ruby .agents/skills/architecture/scripts/resolve_architecture_files.rb <argument>
   ```

   Use the returned `requirements_file`, `final_plan`, `final_plan_alternates`, `primary_plan_candidates`, and `supporting_files`.

   If the resolver cannot identify a single requirements file or final plan, stop and explain the ambiguity instead of guessing.

2. Read the source material.
   - Read the requirements file completely.
   - Read the chosen final plan completely.
   - Read the most relevant supporting context, especially:
     - DHH feedback for the same or previous plan letter
     - earlier plan iterations only when they help explain drift
     - existing `-implementation-review` or `-code-review` files only as supporting context, not as the main artifact
   - Do not load every historical file by default if the later plan and feedback already explain the evolution.

3. Audit the final plan.
   - Check every requirement, constraint, and acceptance criterion for coverage.
   - Flag drift from the original requirements.
   - Flag scope creep that was not requested.
   - Flag contradictions inside the final plan or against established repo conventions when relevant.
   - Treat documented tradeoffs from DHH feedback or later clarifications as intentional changes, not accidental drift, but still call them out.

4. Write the review artifact before replying.
   - Save it in `docs/proposals/plans/`.
   - Name it after the reviewed plan, keeping the same version letter and feature slug, with `-architecture-review.md`.
   - Example:
     - reviewed plan: `docs/proposals/plans/YYMMDD-01c-feature.md`
     - review file: `docs/proposals/plans/YYMMDD-01c-feature-architecture-review.md`
   - If the file already exists, replace it with the updated review instead of creating duplicates.

5. Present findings to the user.
   - Lead with the most important issues.
   - Mention which plan you reviewed and where the review file was written.
   - Keep the chat summary concise. The file is the full artifact.

6. Only if the user explicitly asks to incorporate the review:
   - Create the next plan iteration by incrementing the reviewed plan letter.
   - Base it on the reviewed plan and apply only the approved changes.
   - Preserve the repo naming conventions in `docs/proposals/plans/`.
   - Do not create the next plan automatically.

## Review File Format

Use this structure:

```markdown
# <Feature> Architecture Review

**Date**: YYYY-MM-DD
**Requirements**: `/docs/proposals/requirements/...`
**Plan Reviewed**: `/docs/proposals/plans/...`
**Supporting Context**: `...` or `None`

---

## Overall Assessment

Short high-level summary.

## Requirements Coverage

| Requirement | Status | Notes |
|-------------|--------|-------|

Statuses:
- Covered
- Partially covered
- Missing
- Contradicted

## Drift Analysis

Call out where the final plan diverged from the original requirements and whether the divergence appears intentional.

## Scope Creep

List additions that were not asked for in the requirements.

## Risks and Concerns

Flag architectural risks, unresolved edge cases, internal inconsistencies, or implementation concerns.

## Suggested Changes

1. Concrete, actionable fix.

## Verdict

Brief overall assessment of whether the plan faithfully serves the requirements.
```

If you find no meaningful issues, say so clearly in both the file and the user-facing summary.

## Notes

- If `final_plan_alternates` is non-empty, explain in the review why one plan was treated as the primary final plan and mention the alternates in supporting context.
- Focus on substance, not formatting polish.
- Quote sparingly. Summaries and specific references are usually better than long excerpts.
