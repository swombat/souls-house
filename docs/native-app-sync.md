# Native-app live sync (issue #94 B)

How the Android and iOS clients keep an open conversation fresh. The decisions
behind this are ADR 0003 (auth and API) and ADR 0004 (chat synchronization).

## Opening the cable

1. `POST /api/app/v1/cable_ticket` with the bearer token. Response `201`:
   `{ ticket, protocol, expires_at }`. The ticket works once, within 60 seconds.
   Only its digest is stored.
2. Open the WebSocket to `/cable` offering two subprotocols, in this order:
   `Sec-WebSocket-Protocol: actioncable-v1-json, <protocol>`. The server selects
   `actioncable-v1-json`. Never put the ticket in the URL.
3. A connection that offers a ticket is authenticated by the ticket alone. A
   spent, expired or unknown ticket, or one whose device session is revoked, is
   refused, even if a web cookie is present. Get a new ticket for every connect
   and reconnect.

## Subscribing

`{ channel: "AppSyncChannel", conversation_id: "<conversation id>" }`. The
subscription has the HTTP API's authority: a live device session and current
confirmed membership of the conversation's account (no site-admin widening). If
the API would 404, the subscription is rejected.

Each message revision in the conversation is announced after its transaction
commits:

```json
{ "type": "changed", "conversation_id": "…", "latest_revision": 42 }
```

That is the whole payload. It never carries content. On receipt, call
`GET conversations/:id/changes?since=<your cursor>`. Coalesce bursts, but
never drop the last invalidation.

## Disconnects

- Device session revoked (sign-out, reuse detection, user revocation): the
  connection is closed with `reconnect: false`. Sign in again.
- Membership removed or unconfirmed, or the account disabled: all of the user's
  app connections are closed with `reconnect: true`. Reconnect with a new ticket.
  Subscribing to a conversation you've lost access to is rejected.
- Both happen after the change commits. A disconnect can race a new connection,
  so each subscription also rechecks its authority every 30 seconds.

## Reconciliation (normative)

Broadcasts are invalidations, not delivery. A broadcast can be lost (server
restart, network drop, a failed broadcast after a committed write). The client
must call `changes`:

- immediately on foregrounding the app,
- immediately on every cable (re)connect, after the subscription is confirmed,
- every **30 seconds** while a conversation is on screen and the device is
  online and in the foreground.

The 30 seconds is a polling interval while active and online. It is not a
guaranteed freshness or delivery deadline: offline or backgrounded, the client
catches up on the next foreground or reconnect. The client implementation needs
its own tests for these three triggers.

## What a send wakes

A message's `dispatch` (and an invoke's `invocation`) reports what became of
the wake it caused. `kind` is `mention` (a human message that named residents
in a room with several), `automatic` (a human message in a room with exactly one
resident, which is always woken, whether or not it was named) or `invoke` (an
explicit native invoke). An automatic wake is not a mention and the client must
not present it as one. `pending` or `reserved` means the wake was recorded,
not that a resident started.
