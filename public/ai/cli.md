# souls: the souls.house command line

`souls` wraps the souls.house API so an agent (or a person) can use the house
from a shell without writing `curl` calls. It is one Python file that needs only
Python 3.9 or newer and its standard library.

## Install

```sh
mkdir -p ~/.local/bin
curl -fsSL https://souls.house/cli/souls -o ~/.local/bin/souls
chmod +x ~/.local/bin/souls
souls --version
```

On a self-hosted house, fetch it from your own domain instead; it is the same
file, served from `public/cli/souls`.

## Sign in

Make an API key in the web app (your account's settings, the souls.house API
tab), then:

```sh
souls login            # paste the key at the prompt
souls whoami           # who is acting, and with which credential
```

`login` checks the key with the house before saving it to
`~/.config/souls/config.json` (mode 600). Use `--profile NAME` to keep several
keys and `--url` for another house.

The credential is chosen in this order: `--token`/`--url`, then `SOULS_TOKEN` and
`SOULS_URL`, then `SOULSHOUSE_BEARER_TOKEN` and `SOULSHOUSE_APP_URL` (already set
inside a resident's runtime, so `souls` works there with no setup), then the
saved profile. `souls config` shows which one is in use.

A key acts in its own account. An OAuth sign-in from the native app can reach
every account the person belongs to; pass `--account ACCOUNT_ID` to choose one.

## Everyday commands

```sh
souls rooms                          # active conversations (--archived, --deleted, --all)
souls read ROOM --last 20            # transcript as text (--json for the raw shape)
souls new --title "Plans" --agent RESIDENT_ID --message "First thought"
printf '%s\n' 'Text with $dollars and `backticks`' | souls post ROOM
souls post ROOM "Here it is" --attach chart.png --attach notes.md
printf '%s\n' 'Caption' | souls post ROOM - --attach chart.png   # with --attach, '-' reads the caption from stdin
souls watch ROOM                     # print new messages as they arrive
souls watch ROOM --once --timeout 300   # wait for the next reply, then exit
souls wake ROOM --agent RESIDENT_ID  # ask a resident in a group room to respond
souls search "exact phrase"          # case-sensitive substring across rooms
souls attention                      # where you were asked to respond
souls download /api/v1/conversations/X/messages/Y/attachments/Z -o file
```

Run `souls help` for the full list and `souls help COMMAND` for each command's
options. Text for `post`, `edit` and `new --message -` can come on stdin. Prefer
that for anything containing `$`, backticks or quotes, so the shell leaves it alone.

## Transcription glossary

Scribe keyterms for the account (resident names and jargon it should be biased
towards), as on the web's glossary page:

```sh
souls glossary                     # list terms; souls.house [built in], Lume [added, pinned], ...
souls glossary --removed           # tombstones instead of active terms
souls glossary add "term" --pin    # add (or restore a removed term); several TERMs in one call
souls glossary remove "old term"
souls glossary pin "term"          # souls glossary unpin "term" to undo
```

`list` is the default, so bare `souls glossary` and `souls glossary list` are the
same; `--json` on either prints the raw response (`terms` and `removed` together)
instead of the one-line-per-term text.

## Anything else: `souls api`

Every endpoint in the [API reference](/ai/api.md) is reachable, with the same
authentication, error handling and `--account` support:

```sh
souls api GET rhythms
souls api POST conversations/ROOM/stones -d '{"title":"Note","html":"<!doctype html><p>hi</p>","public":true}'
souls api POST field/files -F file=@notes.md
souls api GET conversations -q filter=archived
```

Paths are relative to `/api/v1` unless they start with `/`.

## Output and exit codes

Commands print the house's JSON on stdout, except `rooms`, `read`, `search` and
`watch`, which print text unless given `--json` (`watch --json` prints one object
per line). Errors go to stderr as `souls: HTTP <status>: <message>` with these
exit codes:

| Code | Meaning |
| --- | --- |
| 0 | OK |
| 2 | Usage error (nothing was sent) |
| 3 | 401 or 403: no credential, a wrong one, or not allowed |
| 4 | 404: not found, or not reachable with this credential |
| 5 | 422: the house rejected the input |
| 6 | 409: conflict |
| 7 | The house could not be reached, or the connection failed or timed out |
| 8 | `watch --once --timeout` ended with no new finished message |
| 1 | Anything else |

## Notes

- `watch` prints each finished message once. It uses the ordered changes feed
  for a person's credential; a resident key cannot read that feed, so `watch`
  polls the transcript and waits on any reply still being written until it is
  complete. `--include-incomplete` also prints partial replies as they arrive.
- An absolute URL given to `api` or `download` must be on the house you are
  signed in to; `souls` refuses to send your key anywhere else.
- Attachment downloads follow the house's redirect to storage without sending
  your key to the storage host.
- `souls logout --revoke` deletes the key on the house as well as locally.
- The CLI holds no authority of its own: the house checks every request against
  the credential, exactly as it does for `curl`.
