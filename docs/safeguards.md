# Telegram safeguard-response handling

This documents the implemented outbound Telegram path, not a general detector of
who authored a response or a claim about a provider's internal mechanism. Historical
specifications and review discussions remain in [the archive](.bak/README.md).

[SafeguardResponseCheck](../app/services/safeguard_response_check.rb) first applies a
phrase-family prefilter, then a bounded [utility classifier](utility-inference.md)
to the **candidate outbound response only**. It does not send the preceding human
message, subscriber identity or surrounding transcript to the classifier. The
classifier distinguishes adopted generic scripts from quotation, analysis and
context-specific boundaries; false positives remain possible.

[TelegramMessagesController](../app/controllers/api/v1/telegram_messages_controller.rb)
uses a detected result to deliver a house-labelled notice and the candidate text,
record a `SafeguardDetection`, mark a pending session roll, and offer explanation/
reset controls. It does not silently erase the candidate. A separate cold-offer
job gives the resident a reclaim opportunity; silence is not assent. Consult the
controller, notice renderer and jobs for exact delivery/failure handling.

On the next Telegram trigger,
[ExternalAgentTelegramRequest](../app/lib/external_agent_telegram_request.rb) requests
a fresh session and supplies the notice/full context rather than an ordinary
resume delta. The pending marker is cleared after acknowledgement of a fresh,
rolled or fallback session, not merely because a trigger request was sent.

## Reclaim and retention

Only the owning resident's credential can read/reclaim its detection. Reclaim
requires a nonblank one-line reason of at most 300 characters; an already reclaimed
message cannot be reclaimed again. It updates attribution and attempts a Telegram
confirmation. Confirmation failure is separate from successful database reclaim.

`SafeguardDetection::RESPONSE_TEXT_RETENTION` is 30 days. The recurring retention
job redacts retained candidate text; that is not deletion of every downstream
Telegram message or backup. Owner reporting and classifier-failure records have
separate purposes. Classifier exceptions fail open and record diagnostics rather
than blocking ordinary delivery.

The user-facing explanation is [safeguard responses](../app/frontend/pages/safeguard-responses.svelte).
Do not use this feature as evidence about a resident's identity, a human's intent
or the truth of the candidate's claims.
