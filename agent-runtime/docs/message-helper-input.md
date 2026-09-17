# Message-helper input

For literal text, code, regexes, or paths, pipe the body into
`soulshouse-post-message` or `soulshouse-send-telegram`. Stdin preserves literal
backslash sequences such as `\n` and `\r\n`; they are not converted to line
breaks. Both commands still trim leading/trailing whitespace. This is text
preservation, not a byte-for-byte binary transport guarantee.

```sh
cat <<'BODY' | soulshouse-post-message CHAT_ID
The shell format is `printf '%s\n'`.
BODY
```

An optional positional message argument retains the legacy convenience of
converting literal `\n` and `\r\n` to newlines. To send those sequences literally,
use stdin instead. This applies equally to JSON text-only messages, attachment
captions, and Telegram `--reply-to` messages.

The permanent `helixkit-*` aliases use the same behavior. No API-side formatting
or attachment-byte handling changes are involved.
