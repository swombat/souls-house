# Resident Memory tab

Every resident edit page has a lazy-loaded, read-only Memory tab. Account members
can see aggregate journal/node/edge counts and fourteen daily bars, including
today. Site admins alone can request the private history endpoint. Account
ownership is not sufficient. Authorization happens before the archive is read.
No resident model is invoked, and inspection never starts a stopped container.

## Timeline and dates

History combines surviving graph nodes and individual second-level Markdown
entries, newest first, with 50 items per cursor page. All five filters start on:

| Filter | Source |
| --- | --- |
| Journals | `memory/daily-journals/YYYY-MM-DD.md` |
| Day summaries | `memory/weekly-journals/YYYY-MM-DD.md` |
| Week summaries | `memory/monthly-journals/YYYY-MM.md` |
| Month summaries | `memory/yearly-journals/YYYY.md` |
| Nodes | Resident's Mnemodyne vault |

Fenced examples do not split entries. Nonempty headingless files appear as one
entry; an empty file or lone first-level file title is not an entry. README files
are excluded. Source paths and bodies are rendered as text, never executable HTML.

Graph dates use `created_at` in UTC (not decay/update times). Historical Markdown
files do not retain per-entry insertion times: journals sort by file date plus
heading time as written; consolidations by the heading's summarized period, with
file-date fallback. These inferred wall-clock dates are not timezone conversions.
Ties within a file use byte-offset order. The UI explains this distinction.
Graph counts include dormant nodes and all node types, but cannot reconstruct
deleted records. The history is a live view, not an immutable event ledger.

## Read limits and failures

The app validates runtime ownership and the configured Docker host before a
read-only Python inspection. Every filesystem ancestor is opened without following
symlinks. Only dated files in the four fixed directories are eligible. There is
no user-supplied filesystem path. Overview mode exports aggregates only; the
separately cached admin catalog contains descriptors, not journal bodies.
Both caches expire after two minutes and are resident/container scoped.

Scans are bounded to 10,000 files, 20,000 entries, 4 MiB per file and roughly
64 MiB total (at most one file beyond that threshold). Exceeding a bound or skipping
an unreadable file is visibly partial; transport/ownership failures are unavailable,
not zero. Container execution has a 25-second timeout with a 30-second outer bound
and a 16-MiB stdout limit. No private content is logged.

Only the selected page's bodies are fetched, with content fingerprints checked
against the catalog. Changed files get an explicit refresh notice instead of
misaligned text. Entries over 64 KiB and nodes with more than 200 connections have
explicit truncation notices. Node responses allowlist fields and omit embeddings
and arbitrary metadata. Cursors are signed, expire after a day, and are bound to
the resident and selected filters; invalid cursors are rejected before file reads.

Tests: `memory_archive_test`, `memory_history_test`, `memory_overview_test`,
`memory_overviews_controller_test`, `ResidentMemoryPanel.test.js`, and
`test/e2e/resident_memory.spec.js`. E2E covers the real edit-page tab and responsive
layout with synthetic memory responses; authorization and graph queries are
covered by Rails integration/service tests.
