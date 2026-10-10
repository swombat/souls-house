# Imported residents on their own VM (design, next slice after #246)

Daniel, 2026-10-09 (KjXOAe): "the VM is just a substrate". Imported residents
go on VMs too, with no difference from local ones. New residents came first
(#266, #269, #270); this is what imports need on top. Not built yet.

## What differs from a birth

| | New resident | Archive import | GitHub import |
|---|---|---|---|
| Home source | exporter tarball | `resident/{identity,repo,work}` from the archive | reviewed checkout → identity |
| After seeding | start, backup, orient | **inactive and paused** until a person activates it | start if the imported runtime is trusted, else `needs_runtime_trust` |
| Env | standard | `home_profile_env_args`: profile, portable home id, imported root, `AGENT_REPO_PATH`, `TZ` | the same plus the `SOULSHOUSE_GITHUB_IMPORT_*` set |
| House-side checks | none | graph import (house DB, unchanged) | `imported_runtime_trusted?` reads the Chaos volume |

## Proposed

1. **Seed per volume.** `seed_home` takes `role ∈ {identity, repo, work}`. Each role has its own archive, digest and marker in its own volume (the same staging, marker and refusal rules as #266). The house keeps one stored archive per (placement, role), so retries name the same bytes.
2. **Admission.** Both import paths admit a VM placement through `VmBirthPolicy#admit!` (the same lock and cap) instead of refusing. The placement records its kind (`birth` | `archive_import` | `github_import`).
3. **One job, three endings.** `ProvisionVmAgentJob` runs order → enroll → seed (all roles), then:
   - birth: start → first backup → ready → orient (as now)
   - archive import: stop there; the placement waits. **Activation** (the existing portability activate action) runs start → first backup → ready, with no orientation.
   - GitHub import: the trust check through the runner (below), then start → first backup → ready; if untrusted, `needs_runtime_trust`, as locally.
4. **Env.** `RemoteRuntime.environment` adds `home_profile_env_args` and the GitHub import set, built by the same helper the local sandbox uses (extracted, so the two can't drift). The runner allowlist gains exactly those names.
5. **Trust check through the runner.** A fixed `inspect_trust` command reads only the one marker file the local check reads in the Chaos volume, and returns a boolean.
6. **Deadline and cleanup.** The same as births, except that an archive import waiting for activation is past provisioning: it has no deadline, but it holds a server and counts against the cap. Site Admin shows such residents as "waiting for activation", and deleting the import cleans up the server.

## Open for Daniel

- Is an imported resident sitting inactive on a paid VM acceptable, or should the VM be ordered only at activation? Ordering at activation is cheaper and makes activation take about 5 minutes; ordering at import is faster to activate but costs money while it waits. My default: **order at activation**. The house holds the archive until then; it's already in the house during import.
