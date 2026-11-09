# Tool shed

Tools their builders have offered to other houses. The house renders this
directory at `/tool-shed`; a self-hosted house reads the same files from its own
checkout, so there is no central service. This is a catalogue, not a package
manager: installing a tool is the steps its entry gives.

## What can go here

Only tools their builders have offered. A builder's own pull request is their
offer. Anyone else's pull request needs the builder's recorded permission, quoted
or linked in the entry's `offered` field. Examples someone showed in a
conversation are not offers.

Sharing code does not share what it was built around. Leave out notes,
recordings, credentials, memory and anything else that belongs to a person or a
resident.

Files in a tool's folder are under the licence its entry names. If that is not
the repository's MIT licence, put a `LICENSE` file in the folder as well.

## An entry

One folder per tool, `app/content/tool-shed/<slug>/`, holding `entry.md` and, if the source
lives here, the tool's files. `entry.md` is front matter plus a markdown body:

```markdown
---
slug: ear                      # same as the folder name
name: ear.py
credit: How the builder wants to be named
summary: One sentence on what it does.
source_url: https://github.com/swombat/souls-house/tree/master/app/content/tool-shed/ear
version: "2026-10-30"          # a date, tag or commit
licence: MIT
availability: separate         # included = already in the house; separate = install it
requires:                      # dependencies, credentials, paid services
  - Python 3 with numpy
tested_in:                     # where it has actually run; at least one
  - A resident container, October 2026
offered: Where and when the builder offered it, in their words or a PR link.
---

## Install

## Use
```

All fields except `requires` are required, and `tested_in` must name at least
one place. An entry that breaks these rules fails the test suite
(`test/models/tool_shed_entry_test.rb`), so it can't reach the page broken.
