# Song cards in conversation replies

Daniel's first slice: residents can offer an existing Field song as a compact
card inside a reply. The reference is `[[song:ID]]` in its own Markdown
paragraph. The ID is the opaque Field song ID. Code blocks and inline code
remain literal; arbitrary HTML and external URLs are not card references.

The assistant message renderer recognises that paragraph through Streamdown's
paragraph hook. Everything else keeps the normal Markdown renderer. A card
uses the conversation's account ID, not an account supplied in the tag, and
reads `GET /accounts/:account_id/field/songs/:id` with the viewer's session.
The controller requires account membership, the agents feature and a kept
song in that account. The response is private and not cacheable.

The message retains only the reference: song edits are reflected on a fresh
read, and missing/discarded/inaccessible songs become unavailable rather than
retaining a copied title or lyrics. Playback revalidates the reference before
loading a source. There is no external thumbnail, player iframe or audio
element before an explicit playback action. Embed URLs use the existing
provider/validated-ID helpers. Audio is preferred when present; provider
links remain available if an embed is blocked. Lyrics expand independently.

No new song is created by rendering a reference. The follow-up below adds
outside offers. No wake-on-share, public publishing, new player provider
or database migration is included.

## Outside offers (follow-up, #367)

Daniel approved the follow-up in Planning `PJvnaJ` (`JyWnwe`), with Lume's
design check `YQVzXJ`; implementation/review lives in `WjmPbe`.
`[[song:URL | Title | Artist]]` keeps the offer in message text, not in a new
message column or music library. Artist is optional; saving requires a title.
The single-line standalone paragraph grammar escapes literal `|`, `[`, `]`
and `\` with a backslash. Unknown/dangling escapes, extra fields and multiline
tags stay ordinary Markdown. Legacy ID references are unchanged.

The viewer's session calls `GET /accounts/:id/field/songs/offer?url=…`;
the server uses `FieldSong::Links.normalise`, rejects unsupported/unsafe
links and returns `{link, song}` with an existing kept song or null.
No external request is made to resolve an offer. Providers with no supported
embed get an Open on provider link, not a speculative player. Outside offers
carry no lyrics, even after saving; the original Field card can still show
the current Field song's lyrics.

An explicit `POST` to the same endpoint with `{url,title,artist}` saves under
the viewer's account and attributes `added_by` to the clicking user. No note,
recipient or lyrics are invented. Find/create is serialized with an account
row lock. Matches use provider and embed ID where present (including equivalent
YouTube URLs), otherwise the exact normalized URL; normalization upgrades HTTP
to HTTPS and trims outer space but does not strip query parameters. Discarded
matches do not block a fresh save. Existing metadata is never overwritten.
The GET performs the same match so reloads show Open in Field. Authentication,
account membership and the agents feature gate are the same as ordinary web
Field song operations.

Browser verification also exposed an existing refresh loop: dynamic navbar
and sidebar subscriptions reconnected after unchanged serialized props arrived,
and each connection requested another catch-up reload. `createDynamicSync`
now retains an unchanged desired subscription set. Changed channel identities
or requested props still reconnect; real network reconnects still catch up.
This is needed for an expanded card to remain usable during conversation
updates, not a replacement of the sync system.

The card's initialization effect tracks only its account/song identity.
Fetching is untracked so replacement paragraph props during a background
refresh cannot reset expanded lyrics or interrupt an active player.
