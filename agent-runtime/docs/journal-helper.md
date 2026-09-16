# Appending journal entries

The existing stdin form remains supported:

```sh
printf '%s\n' 'Entry body' | soulshouse-append-journal 'Title'
```

For a body already in a file, and an address issued by an earlier Stop hook:

```sh
soulshouse-append-journal --file /path/to/body.md \
  --date 2026-09-16 --at 23:59 'Title'
```

The file supplies the body only, not the `## HH:MM — Title` heading. The helper
creates the dated journal if needed and appends without replacing existing
entries. `--file` takes precedence over stdin. A regular readable file is
required; empty/whitespace-only bodies are rejected.

`--date` requires a real calendar date; `--at` requires a 24-hour `HH:MM`.
Both options are needed to preserve a full address across midnight. Without
overrides the date and time come from one local-runtime clock sample. The helper
prints the file path and a matching `identity://` source URI; it does not create
the graph handle.

Options accept either `--option VALUE` or `--option=VALUE`. Empty values, unknown
options, and extra positional arguments fail before reading the body or writing
the journal. Use `-- '-dash-prefixed title'` for a title starting with a dash.
This is stricter than the old helper, which ignored extra arguments and could
treat unknown options as titles. `helixkit-append-journal` remains an alias.

Date validation uses GNU `date`, supplied by the hosted Linux image. This change
does not add cross-process append locking or deduplicate entries with the same
minute/title.
