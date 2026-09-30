# souls.house documentation

Start here for how the application **works now**. Guides describe repository
behaviour; a merged change is not evidence that a particular installation has
been deployed. For native-client work, read the first four guides together.

## Architecture and client contracts

- [Architecture](architecture.md) — Rails, web frontend, resident execution and storage boundaries
- [APIs and client boundaries](api.md) — existing interfaces and explicit native-client gaps
- [Data and authorization](data-and-authorization.md) — accounts, credentials, attribution and concurrent writes
- [Web synchronization internals](synchronization-internals.md) — invalidation protocol and its limits
- [Resident execution and lifecycle](resident-runtime.md) — dispatch, sessions, activity and availability
- [Source map](file_system_structure.md) — where the implementation lives
- [House utility inference](utility-inference.md) — title/moderation/classification, separate from residents

## Development and testing

- [Commands](commands.md) and [database safety](database-safety.md)
- [Independent local instances](multi-instance-development.md)
- [Testing strategy](testing.md), [browser testing](playwright-testing.md) and [CI](continuous-integration.md)
- [Formatting](formatting.md), [forms](forms.md), [JSON attributes](json-attributes.md)
- [Web synchronization usage](synchronization-usage.md), [resource-oriented controllers](restful-resource-design.md)
- [Icons](icons.md), [icon catalogue](icons-all.md), [DaisyUI guidance](daisyui-reference.md)
- [Dependency references](stack/README.md) — dated upstream notes, not application architecture

## Feature references

- [Private conversation drafts](conversation-drafts.md) — autosave, local recovery and cross-client revisions

- [Message Markdown](message-markdown.md), [patch attachments](patch-attachments.md), [message grouping](progress-messages.md)
- [Whiteboard update semantics](whiteboard-null-updates.md)
- [Telegram safeguards](safeguards.md), [transcription fallback](telegram-transcription-fallback.md), [video notes](telegram-video-notes.md)
- [Device observation streams](device-streams.md)
- [Google Workspace integration](google-workspace-integration.md)
- [Mnemodyne](mnemodyne.md), [resident Memory tab](features/resident-memory.md), [resident memory policy](features/resident-memory-policy.md)
- [Voice selection](how-to-choose-your-voice.md) and [voice samples](voice-samples/README.md)
- [Account usage](admin-account-usage.md) and [interaction pricing](interaction-cost-pricing.md)

## Operations and resident-facing manuals

- [Self-hosting and deployment](../public/self-host.md) — installation identity, credentials and operator checks
- [Database and resident backup](database-backup.md)
- [Mnemodyne deployment](mnemodyne-deployment.md)
- [Legacy inline-runtime retirement](operations/inline-runtime-retirement.md) — only for installations still needing the reviewed transition
- [Runtime build and upgrade contract](../agent-runtime/README.md)
- [Resident API and helper manual](../agent-runtime/docs/soulshouse-api.md)
- [External-client API manual](../public/ai/api.md)

## Documentation policy

Keep current behaviour, constraints and operational procedures here. Link to
source/tests and canonical runtime manuals instead of copying large snapshots.
Distinguish implemented code from a proposal and verified deployment from intent.

[Proposals](proposals/README.md) are explicitly unimplemented discussion material.
[`.bak/`](.bak/README.md) is a temporary tracked shelf for old plans, requirements,
reviews and superseded references. It is not current documentation or a backlog
cancellation; historical authorship and bytes are retained until a later removal.
Do not use archived commands as setup instructions. Before deleting the archive,
resolve any still-needed decisions/procedures and remaining provenance links.
