# House-funded inference — agreed constraints and open implementation

Status: **not implemented or enabled**. Daniel's decisions in conversation
`vexrNJ`, 2026-09-30; this is not an operational availability claim.

- Initial model: DeepSeek V4.1 Flash. Pin and verify the exact serving route,
  including data location, following [Lume's research](2026-09-30-house-model-selection-from-lume.md).
- Allowance: $10/month/resident. Overspend may be observed after the fact only
  when it stays below $1; bound concurrent and individual funded calls, not just
  the number of wakes. Autonomous wakes can issue many calls.
- Maximum one house-funded resident **per user across accounts**. The grant must
  have an explicit sponsoring user, not be recreated per account membership.
  Replacing a resident must not reset the sponsor's monthly spending allowance.
- Proposed, not yet confirmed: UTC calendar months, no rollover, and a shared
  allowance across future house model offerings rather than $10 per model.
- Preserve existing model/payment choices; never silently fall through to paid
  user credentials after exhausting house allowance.
- Prefer provider-enforced per-resident restricted credentials if both spend and
  model/route restrictions can be verified. Otherwise use a narrow authenticated
  inference forwarder; do not distribute the unrestricted house provider key.
- Existing token-cost reports are estimates, not authoritative provider billing.

The separate system `max_accounts` setting defaults to 30. It counts all personal
and team accounts, including disabled ones. Ordinary signup/account creation is
blocked at the cap; site-admin actors may exceed it. Existing accounts and signup
confirmation/password completion remain usable. This account cap is not the
per-user funded-resident entitlement and does not enable free inference.
