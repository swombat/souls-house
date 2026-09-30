# Historical documentation — not authoritative

This tracked, temporary shelf preserves old plans, requirements, reviews, vendor
notes and superseded guides while the live `docs/` tree becomes current reference
material. Nothing here is an instruction to execute a migration or deployment.
Old claims such as “not built”, “done”, test counts and open checkboxes belong to
their original date/checkout; moving a file does not confirm or cancel them.

The existing files were moved without rewriting their contents. `reference/`
contains byte-preserved copies of the guides replaced during the cleanup.
Relative links to other archived siblings often still work; old repository/root
links and historical code paths can be stale. They are deliberately not repaired
inside historical testimony. Use Git history for original locations/context.

## Where to look now

- Current architecture: [architecture](../architecture.md), [API boundaries](../api.md)
  and [data/authorization](../data-and-authorization.md).
- Hosted sessions/caching/lifecycle and provider auth: [resident runtime](../resident-runtime.md)
  and the [runtime manual](../../agent-runtime/README.md).
- Retired RubyLLM/Prompt/tool architecture: [utility inference](../utility-inference.md)
  and the [reviewed legacy transition](../operations/inline-runtime-retirement.md).
- Safeguard specifications: [implemented Telegram handling](../safeguards.md).
- Forkability/credentials: [self-hosting](../../public/self-host.md),
  [credential template](../../config/credentials/production.example.yml).
- Actual development commands and tests: [commands](../commands.md), [testing](../testing.md).
- Still-active proposals: [proposal index](../proposals/README.md).

## Later removal

Git history preserves these records, but removal is a separate change. First
confirm no operational procedure or live reference relies on this shelf, and
resolve/extract any outstanding proposal that remains relevant. Do not interpret
archiving all of `plans/` and `requirements/` as silently abandoning unfinished
work. Dated measurements may remain linked as evidence, not current guarantees.
