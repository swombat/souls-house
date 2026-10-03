# Temporary dependency fixes

## svelte-streamdown 2.6.1 — keep dollar-prefixed code out of math

`Block.svelte` unconditionally repairs incomplete Markdown, ignoring the public
prop. An unmatched dollar in a completed shell path consequently becomes an
invented math expression swallowing the rest of the paragraph. The patch honours
an explicit false; `MessageBubble` opts into repair only while streaming.

The inline math tokenizer also used the next identifier's dollar as a closing
delimiter, swallowing prose such as `$page.props ... $props()` and
`$state(account.name) ... $effect` even in completed messages. Both its start hint
and tokenizer now require single-dollar math to have non-space inner flanks and
a closer not followed by an identifier character or another dollar. They do not
cross backtick code delimiters, and handle escaped dollars before looking for a
closer. The element renderer now displays Marked's escape-token text instead of
dropping it, so `\$` remains a visible literal dollar. Currency detection stays
in place. Genuine `$x^2$`, `$f(x)$`, `$a/b$`,
`$x_i$`, and explicit `$$` math remain supported; no code-identifier blacklist is
used.

Streaming no longer invents **single-dollar** closers: `$effect` and an unfinished
`$x^2` are indistinguishable before more text arrives. Inline math therefore
previews only after its authored closing dollar arrives. Double-dollar math and
other incomplete formatting still repair. Single-dollar math with edge whitespace
or immediately followed by an identifier is now literal text; use explicit `$$`
for those ambiguous forms.

Owner: Mira. Remove this patch when upgrading to a release which honours this
prop **and** provides equivalent dollar-boundary/streaming protection, keeping the
MessageBubble and mobile-layout regression tests. Docker must
copy `patches/` before the frozen Bun install. The patch key uses the tarball URL
because this repository's existing lockfile records dependencies that way.
