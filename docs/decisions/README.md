# Architecture decisions

Read [the current map](../architecture.md) first. Decisions record intended
architecture, not proof that an implementation has shipped. Accepted directions
can still have implementation/consent gates. Do not silently turn a proposal into
an accepted policy.

| ADR                                                               | Direction                                                               | Implementation state at recording                                 |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------- |
| [0001 Recoverable discard](0001-recoverable-discard.md)           | Daniel's app-data policy; resident-owned memory/files excluded          | Compliance audit open (#93)                                       |
| [0002 Reviewed development](0002-reviewed-development.md)         | Issue review, PR review, resident consultation, deployment approval     | Agreed process; no automatic scheduler implied                    |
| [0003 Mobile auth and API](0003-mobile-auth-and-api.md)           | Browser OAuth/PKCE; explicit authorised API context                     | Validation spike and #94 review gates outstanding                 |
| [0004 Chat synchronization](0004-chat-synchronization.md)         | Transactional revisions, retry-safe sends, authoritative reconciliation | #94 B implementation plan approved; consultation and tests remain |
| [0005 Native client boundaries](0005-native-client-boundaries.md) | SwiftUI and Compose; repositories and durable outboxes                  | Toolchain, persistence and dependency validation outstanding      |

Use `NNNN-short-title.md` with **Status / Context / Decision / Consequences**,
date, and links to the originating issue/PR. Amend clarity with review; when the
decision changes, add a new record and mark the old one superseded by it. Preserve
history. The architecture map links the currently applicable decisions.

Issue and PR URLs below are collaboration provenance, not runtime configuration.
Historical design drafts are evidence of what was proposed, not authority over a
newer accepted decision. A broad cleanup/archive of legacy docs is separate work;
do not delete old documents or infer obsolescence solely from their age.
