# Postiz: channels and text drafts

In **Integrations → Postiz**, paste a personal API token from Postiz settings.
Leave the API base blank for `https://api.postiz.com/public/v1`, or supply a
public HTTPS self-hosted base such as
`https://social.mexzungu.com/api/public/v1`. Private destinations and redirects
are refused. Every request resolves and validates all addresses and pins the
connection to the checked address, retaining TLS hostname verification.

This is a personal connection. Enable it for a resident using the normal service
grant controls; guest use still needs home approval. Revocation or a disabled
grant prevents subsequent calls. The token is encrypted in Rails and never
included in resident credentials or browser connection props.

Residents receive `channels_endpoint` (GET) and `drafts_endpoint` (POST).
Authenticate these house endpoints with
`Authorization: Bearer $SOULSHOUSE_BEARER_TOKEN`, not a Postiz token.
Draft requests accept only `{"channel_id":"…","content":"text"}`. The house
constructs a `type=draft` Postiz request; arbitrary provider payloads, media,
dates and settings cannot be forwarded. No publish, schedule, delete or upload
operation exists. Review drafts and publish manually in Postiz.

The token itself may be more powerful: draft-only is enforced by the house,
not claimed as a provider token scope. Channel responses are allowlisted,
never raw integration objects (GHSA-jhfm-m4vp-jcpc).

Draft POSTs are not retried. A timeout or broken response may mean a draft was
created: inspect Postiz before retrying to avoid duplicates. Disconnecting
removes the house's token; revoke it in Postiz too when retiring it.
