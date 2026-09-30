# Source map

souls.house is one Rails application with a Svelte web frontend and a separately
built resident-runtime image. Paths below are navigation aids, not a generated
catalogue of every file.

| Path | Contents |
| --- | --- |
| [app/models](../app/models) | Accounts, residents, conversations, messages, integrations and persistence concerns |
| [app/controllers](../app/controllers) | Browser/Inertia controllers, authorization and `/api/v1` endpoints |
| [app/channels](../app/channels) | Browser-session Cable connection and `SyncChannel` |
| [app/jobs](../app/jobs) | Queue entrypoints; some legacy names are intentionally inert compatibility shells |
| [app/services](../app/services) | Sandbox operations, activity ingestion, utility inference, memory and cost reporting |
| [app/lib](../app/lib) | Runtime request construction, trigger client and integration helpers |
| [app/frontend/pages](../app/frontend/pages) | Inertia page components |
| [app/frontend/lib](../app/frontend/lib) | Chat state, Cable/prop synchronization, formatting and frontend helpers |
| [app/frontend/lib/components](../app/frontend/lib/components) | Reusable UI primitives |
| [app/frontend/entrypoints](../app/frontend/entrypoints) | Vite entrypoints |
| [config](../config) | Routes, environment/queue/storage configuration and credential templates |
| [db](../db) | Migrations, schema and seed definitions; not production backup storage in Git |
| [agent-runtime](../agent-runtime) | Docker build, pinned Chaos revision, trigger shim, helpers and resident-facing docs |
| [lib/house](../lib/house) | Installation identity and self-hosting CLI |
| [scripts](../scripts) | Build, deployment and verification tools; not all are safe local test commands |
| [test](../test) | Rails/Minitest and Python runtime contracts; fixtures and synthetic integrations |
| [playwright](../playwright) | Owned-backend E2E/component runners and browser fixtures |
| [public/self-host.md](../public/self-host.md) | Maintained self-hosting/operator guide |
| [docs/overview.md](overview.md) | Maintained documentation index |

Frontend logic tests are colocated `*.test.js`; browser component fixtures live
alongside the relevant components and under Playwright. Use [testing.md](testing.md)
and [CI](continuous-integration.md) for entrypoints rather than invoking raw runners
that bypass database/process ownership locks.

Generated assets, local databases/uploads, logs, credential keys and installation
identity are not source artifacts to copy between checkouts. Use independent
clones and [instance setup](multi-instance-development.md).

`docs/.bak/` is a temporary tracked historical shelf; `docs/proposals/` contains
explicitly unimplemented proposals. Neither is current architecture. The archive's
old paths and examples are preserved for provenance, not for execution.
