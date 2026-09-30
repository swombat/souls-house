# Develop a kickass spec for a new feature

You will receive a requirements document for a new feature, and use the Docs Fetcher, Application Architect and DHH Code Reviewer sub-agents to develop a great spec for it.

## Steps

Here is the requirements document: $ARGUMENT

### 1. Clarify the requirements

First, evaluate whether the requirements document requires any clarification. If it does, ask the user before proceeding, and append the clarifications to the requirements document in a ## Clarifications section.

Unless the requirements are extremely clear upfront, you should always ask at least 3 clarifying questions - ideally, select the ones which are most likely to reduce ambiguity and result in a great spec, and, later, a great, tight implementation that does what it needs to do and nothing more.

### 2. Fetch documentation

Once you are happy with the basic requirements, decide whether it requires documentation in addition to what is present in the /docs/ folder (consult /docs/overview.md for the documentation structure). If it does, use the Docs Fetcher sub-agent to fetch the relevant documentation and summarise it in a new /docs file. If it is a file about an external tool or library, store the new documentation under /docs/stack/. Don't fetch new documentation for parts of the stack that are already documented, just use what's there and let the other sub-agents fetch more if they need to.

### 3. First iteration of the spec

Use the Application Architect sub-agent to create a first iteration of the spec. Pass it the documentation it needs as well as the requirements.

Chances are that the first iteration of the spec will be bloated and overly complex. That's okay, that's what the application architect tends to do. It's a first draft. It should end up in a file named `YYMMDD-XXa-spec-headline.md` in the /docs/proposals/plans/ folder.

So for example, if the requirements document is `/docs/proposals/requirements/YYMMDD-01-feature.md`, the first iteration of the spec should be called `/docs/proposals/plans/YYMMDD-01a-feature.md`.

### 4. Refine the spec

Pass the first iteration of the spec to the DHH Code Reviewer sub-agent to refine it. Require the dhh-code-reviewer to write all its comments in a file named `YYMMDD-XXz-spec-headline-dhh-feedback.md` in the /docs/proposals/plans/ folder. So for example, if the requirements document is `/docs/proposals/requirements/YYMMDD-01-feature.md`, the first iteration of the spec should be called `/docs/proposals/plans/YYMMDD-01a-feature.md`, and the dhh-code-reviewer's comments should be written to `/docs/proposals/plans/YYMMDD-01a-feature-dhh-feedback.md`.

Check whether the DHH Code Reviewer actually saved its comments in the specified file. If it didn't, save whatever it returned to you in the specified file.

### 5. Second iteration of the spec

Take the first iteration of the spec, the relevant documentation, the requirements and the DHH Code Reviewer's comments, and pass those as context to the Appliction Architect sub-agent to create a second iteration of the spec, applying DHH's feedback.

The second iteration of the spec should be called `YYMMDD-XXb-spec-headline.md` in the /docs/proposals/plans/ folder. So for example, if the requirements document is `/docs/proposals/requirements/YYMMDD-01-feature.md`, the first iteration of the spec should be called `/docs/proposals/plans/YYMMDD-01a-feature.md`, and the dhh-code-reviewer's comments should be written to `/docs/proposals/plans/YYMMDD-01a-feature-dhh-feedback.md`, the second iteration of the spec should be called `/docs/proposals/plans/YYMMDD-01b-feature.md`.

### 6. Refine the spec again

Repeat the DHH review process for the second iteration of the spec.

### 7. Third iteration of the spec

Repeat the Application Architect process for the third iteration of the spec.

### 8. Pause and notify the user that the spec is ready for review

The user will want to review the spec in detail before proceeding to implementation.

In your notification, summarise the key, final components of the spec at a very high level (3 paragraphs max), and also summarise the key changes that were made thanks to DHH's suggestions (also 3 paragraphs max). Use paragraphs rather than bulletpoints.

### 9. Afterwards: build with sub-agents

Use the rails-programmer primarily, and svelte-developer as needed, to actually build the feature with sub-agents, rather than cluttering your context with the entire build. Instruct them to use the `agent-browser` skill (invoke with `/agent-browser`) to check the functionality works as expected, as well as writing automated tests.

Once they have finished building the feature, please review their code output yourself to ensure they have not deviated substantially from the spec without good cause.