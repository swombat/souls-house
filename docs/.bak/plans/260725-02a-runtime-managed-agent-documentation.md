# Runtime-managed documentation for hosted agents

**Date:** 2026-07-25
**Status:** Implemented 2026-07-26 after review by Lume
**Related:** `docs/requirements/260725-01-agent-image-generation.md`, `docs/requirements/260725-01-agent-image-generation-review-from-mira.md`, `docs/plans/260616-01d-persistent-chaos-sessions.md`

---

## 1. Summary

Move HelixKit's changing operational documentation out of each agent's
persistent identity volume and into the versioned hosted-agent runtime.

The current image-attachment implementation works, but existing agents may
still read an old `identity/helixkit-api.md` created when their identity volume
was first seeded. Updating `AgentIdentityExporter` only helps newly created
agents, while appending one-off patches from `entrypoint.sh` turns every new API
capability into another migration against agent-owned files.

The cleaner boundary is:

| Owner | Contents |
|---|---|
| Agent identity volume | `soul.md`, `self-narrative.md`, journals, memories, and other agent-authored continuity |
| Hosted runtime image | HelixKit API reference, helper-command documentation, runtime mechanics, and capability notes |
| Chaos | Native tool schemas and provider/model-specific behavior |

The runtime should inject a short, current operating guide on each fresh Chaos
session and make the full reference available at a stable runtime path. Existing
identity files should be left untouched, even when they contain an older
HelixKit manual.

This fixes the immediate documentation gap without teaching HelixKit how image
generation works, editing identity repositories, or adding a documentation
synchronization subsystem.

---

## 2. Problem

`AgentIdentityExporter` currently seeds both:

- `identity/runtime-instructions.md`
- `identity/helixkit-api.md`

These files describe platform behavior rather than the agent's identity, but
they live on the persistent identity volume and therefore acquire conflicting
properties:

1. They look agent-owned and editable.
2. HelixKit still needs to update them as the platform changes.
3. Existing volumes do not receive exporter changes.
4. `entrypoint.sh` has started appending version-marked fragments to compensate.
5. A fragment can add a capability but cannot reliably revise or remove stale
   surrounding guidance.
6. The same long Markdown reference is embedded in Ruby, while boot-time patches
   are embedded separately in shell.

The image-attachment feature exposed the failure mode. The runtime helper
already supports:

```sh
helixkit-post-message "$CHAT_ID" --attach /tmp/image.png
```

but an existing agent may consult a persisted manual that predates `--attach`.
The implementation and executable are current; the copied documentation is
not.

---

## 3. Design principle

> Documentation should travel with the capability it documents.

`helixkit-post-message`, `trigger_shim.py`, and the HelixKit callback contract
ship in the hosted-agent image. Their manual should ship in that same image.

This is analogous to Rails keeping framework behavior and generated application
state separate:

- do not copy framework documentation into every application's mutable domain
  data;
- keep one canonical source beside the implementation;
- expose a small conventional entry point for discovery;
- let upgrades replace framework code and framework docs together.

The identity volume remains available for the agent to write its own notes. If
an agent chooses to record a personal workflow there, that is theirs. HelixKit
should not mutate it to distribute release notes.

---

## 4. Proposed runtime layout

Add ordinary Markdown source files under `agent-runtime/`, for example:

```text
agent-runtime/docs/runtime-instructions.md
agent-runtime/docs/helixkit-api.md
```

Copy them into the image:

```text
/usr/local/share/helixkit-agent/runtime-instructions.md
/usr/local/share/helixkit-agent/helixkit-api.md
```

These files become the canonical hosted-agent documentation. They are:

- versioned with HelixKit;
- immutable inside a running image;
- upgraded with the helpers and shim they describe;
- outside `/home/agent/identity`;
- readable directly by the agent when more detail is needed.

`helixkit-post-message --help` remains the most precise source for that helper's
arguments. The broader manual should point to executable `--help` for command
syntax rather than duplicating every option indefinitely. Each `helixkit-*`
helper should include a one-line footer pointing to the full bundled manual;
there is no need for a separate `helixkit-help` command.

---

## 5. Prompt assembly

### 5.1 Keep soul first

On a fresh session, `trigger_shim.py` should assemble:

1. `identity/soul.md`
2. bundled runtime instructions
3. `identity/self-narrative.md`
4. `identity/bootstrap.md`
5. the live HelixKit request
6. recent journal context

This preserves the current sovereignty rule: `soul.md` remains the first text
the model sees. Runtime instructions are clearly labelled as hosting context,
not identity.

The bundled runtime section should include the stable path to the full manual:

```text
/usr/local/share/helixkit-agent/helixkit-api.md
```

It should also say explicitly that a pre-existing
`identity/helixkit-api.md` may be a historical export and is not the
authoritative platform reference.

### 5.2 Keep the injected section short

Do not inject the entire API manual into every fresh session. The injected
runtime instructions need only cover:

- where the current manual lives;
- the available helper commands;
- how to read and post to HelixKit;
- the local-file-to-message attachment seam;
- shell-safety guidance;
- the distinction between runtime mechanics and identity.

Detailed endpoint examples remain in the bundled reference and can be read on
demand.

### 5.3 Image-generation wording

The runtime guide should document the durable workflow, not volatile provider
instructions:

1. Use the current model/runtime's available image-generation capability.
2. Save or locate the resulting local image file.
3. Attach it atomically to a HelixKit message with
   `helixkit-post-message --attach`.

It may mention that Chaos currently saves completed native OpenAI image outputs
under `/tmp/<image_id>.png`, because that is a runtime behavior shipped alongside
the guide. It should not maintain a model list, pricing table, OpenRouter payload
schema, or claims about which model is currently best.

Provider cost reporting remains natural agent work: if the tool/provider reports
cost, the agent may include it in its message. HelixKit does not need a cost
documentation or accounting abstraction for this feature.

---

## 6. Persistent-session correctness

Fresh prompt assembly alone is insufficient because hosted agents resume Chaos
sessions. After a runtime-image upgrade, the `.chaos` volume and its HelixKit
session sidecars survive, so the shim could otherwise resume a session that only
knows the old runtime guide.

Extend the sidecar fingerprinting to distinguish:

- **identity fingerprint** — agent-owned files that currently cause
  `identity-changed`;
- **runtime-context fingerprint** — bundled files injected into a fresh prompt.

Fingerprint the exact assembled runtime section that enters the prompt,
including its label, provenance, stable manual path, conditional legacy-file
warning, and bundled instruction text. Hashing the assembled string means a
change in either the Markdown or the shim-owned wrapper rolls the session
without relying on a manually maintained prompt version.

Store that hash in the session record. When it changes:

1. retire the old mapped Chaos session;
2. start a fresh session;
3. inject the new runtime context;
4. report a roll reason such as `runtime-context-changed`.

Do not report this as `identity-changed`: a platform upgrade is not an identity
edit.

Store the fingerprint when the session is created and do not refresh it during
ordinary resumed turns: it describes what that session was born with.

Do not fingerprint the full on-demand API manual. It is not frozen into the
session; reading its stable path after an image upgrade returns the current
copy. The injected guide should remind agents to re-read the manual before
relying on endpoint specifics because remembered details may predate the current
runtime image.

---

## 7. Identity-volume migration policy

### Existing agents

Do not delete, overwrite, append to, or rename:

- `identity/runtime-instructions.md`
- `identity/helixkit-api.md`

They may contain agent edits or annotations. The new runtime instructions should
simply identify them as possible historical exports and direct the agent to the
runtime-owned reference.

Remove the boot-time patching blocks that append shell-safety and Telegram
sections to `identity/helixkit-api.md`. Once the runtime guide is canonical,
those migrations are unnecessary and violate the ownership boundary.

The existing `runtime-instructions.md.new` fallback mechanism can also be
retired after the bundled runtime instructions are injected directly. Preserve
already-created `.new` files: although HelixKit originally generated them, an
agent may since have annotated or repurposed them. The conditional legacy-file
warning should name them explicitly rather than deleting them.

### Newly created agents

Stop exporting platform manuals into new identity tarballs. New identity
volumes should contain continuity-bearing files only:

- `soul.md`
- `self-narrative.md`
- `bootstrap.md`
- memory/journal scaffold
- exported legacy memories, where applicable

Revise `bootstrap.md` to point to the runtime-owned manual rather than an
identity-relative `helixkit-api.md`.

This changes the seed shape for future agents but does not modify any existing
agent's identity folder.

---

## 8. Canonical source and duplication removal

The Markdown files under `agent-runtime/docs/` should be the only source of the
runtime manual.

Remove the large `helixkit_api_md_content` heredoc from
`AgentIdentityExporter`. Avoid recreating the same text in `entrypoint.sh`.

Where Rails tests need to assert documentation behavior, read the canonical
Markdown file rather than invoking a Ruby method that manufactures a copy.

Keep command-specific usage close to each executable:

- `helixkit-post-message --help`
- `helixkit-send-telegram --help`
- `helixkit-append-journal --help`, if supported

The Markdown manual explains when and why to use the commands; their own help
defines exact syntax.

---

## 9. Implementation steps

1. **Extract canonical docs**
   - Move the current hosted runtime instructions and API reference into
     `agent-runtime/docs/`.
   - Update attachment guidance to describe the shipped `--attach` flow.
   - Remove volatile image-model/provider advice.

2. **Bundle docs with the runtime**
   - Copy the files into `/usr/local/share/helixkit-agent/` in the Dockerfile.
   - Point existing helpers' `--help` output to the full manual.

3. **Inject runtime context from the runtime**
   - Add a runtime-doc path/config to `trigger_shim.py`.
   - Read bundled runtime instructions after `soul.md` and before the remaining
     identity context.
   - Stop reading `identity/runtime-instructions.md` into prompts.
   - Remove `runtime-instructions.md` from `IDENTITY_FINGERPRINT_FILES`; editing
     the preserved historical file must not roll a session.

4. **Roll stale persistent sessions**
   - Fingerprint the exact assembled injected runtime section and store that
     birth fingerprint in session sidecars.
   - Roll with `runtime-context-changed` when bundled injected context changes.
   - Preserve the separate identity-change reason and diagnostics.

5. **Stop mutating existing identities**
   - Delete the API-fragment append migrations and runtime-instructions refresh
     logic from `entrypoint.sh`.
   - Leave existing files on the mounted volume untouched.

6. **Simplify future identity exports**
   - Remove platform manuals from `AgentIdentityExporter#files`.
   - Update bootstrap references.
   - Preserve all identity and memory exports.

7. **Update developer documentation**
   - Document the runtime/identity ownership boundary in
     `agent-runtime/README.md`.
   - State that capability documentation changes require a runtime image build
     and normal hosted-agent image rollout, just like helper changes.
   - Name the existing `stop_journal_reflex.py` copy under
     `identity/automation/` as a deliberate bounded exception retained for
     visibility in the hosting filesystem browser.

---

## 10. Tests

### Prompt tests

- `soul.md` remains first.
- Bundled runtime instructions appear immediately after soul.
- A stale `identity/runtime-instructions.md` is not injected.
- Editing that preserved historical file does not roll a session.
- The runtime section points to the canonical bundled API reference.
- Request text still precedes journal context.

### Session tests

- Sidecars record both identity and runtime-context fingerprints.
- Changing agent identity rolls with `identity-changed`.
- Changing bundled runtime instructions rolls with
  `runtime-context-changed`.
- Changing only the shim-owned wrapper around those instructions also rolls
  with `runtime-context-changed`.
- Touching either file without changing content does not roll.
- A legacy sidecar without a runtime fingerprint upgrades safely by taking one
  fresh session rather than resuming with unknown documentation state.

### Exporter tests

- New exports still include soul, self-narrative, bootstrap, journals, and
  memories.
- New exports do not include runtime-owned manuals.
- No conversation transcript is exported.
- Bootstrap points to the runtime manual's stable path.

### Entrypoint/runtime tests

- The Dockerfile copies both canonical Markdown files.
- `entrypoint.sh` contains no writes or appends to
  `identity/helixkit-api.md` or `identity/runtime-instructions.md`.
- Existing arbitrary identity files survive a boot unchanged.
- Existing `runtime-instructions.md.new` files survive unchanged and are
  described as historical by the runtime guide.
- `helixkit-post-message --help` documents repeatable `--attach`.

### Existing image-attachment coverage

Keep the controller, helper, VCR integration, and browser rendering tests added
for agent image attachments. This documentation change should not alter the
message API or attachment behavior.

---

## 11. Acceptance criteria

1. An existing hosted agent can be upgraded to a new runtime image without any
   HelixKit process editing its identity files.
2. Its next trigger receives current runtime instructions; a stale resumed
   session is rolled automatically.
3. The agent can find the full current API manual at a stable runtime-owned path.
4. The manual describes `helixkit-post-message --attach`, and the executable's
   own help confirms the syntax.
5. Old identity manuals remain present and unchanged but are clearly noncanonical.
6. A newly created agent does not receive copied platform documentation in its
   identity seed.
7. Future helper/API documentation changes require editing one canonical
   Markdown source and rebuilding the runtime image, not writing an identity
   migration.

---

## 12. Non-goals

- No dynamic documentation service or new HelixKit API endpoint.
- No per-agent documentation synchronization.
- No deletion or cleanup migration for old identity manuals.
- No image-generation wrapper, provider client, or model registry.
- No requirement that agents preserve HelixKit's runtime guide in their own
  repositories.
- No attempt to make runtime docs update without a runtime image upgrade; code,
  helpers, and their documentation should move together.

---

## 13. Review questions for Lume

Lume's review resolved the implementation choices:

1. Fingerprint only the exact injected runtime section, not the full manual.
2. Use existing helpers' `--help` output for rediscovery; add no new command.
3. Keep `bootstrap.md` identity-side as a historical birth artifact.
4. Move both operational files together.

The one deliberate departure from the review is cleanup of
`runtime-instructions.md.new`: preserve it rather than deleting it because its
contents may have become agent-authored after HelixKit created the file.
