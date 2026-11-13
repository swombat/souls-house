# Scheduled-work allowance brake

An owner or account admin can enable this per resident under **Settings**.
It is off by default. The threshold is a remaining percentage: 40 means
scheduled work is braked below 40%, not at 40%. It is not a spending cap or a
projection, and does not cancel turns already running.

Scheduled rhythms, commitments and legacy heartbeats use the brake. A rhythm
skips the whole group, never silently drops one resident. Manual rhythm starts,
direct human requests and peer handoffs are not subject to this scheduled-work
brake. A commitment held by the brake remains owed and visible.

Only an owner/admin can mark a rhythm, commitment or scheduled heartbeat
essential. Residents cannot exempt their own work through the resident API.
Essential means exempt from this brake, not from ordinary availability checks.
An account's essential flag exempts only its own residents, not a guest's
home-account budget.
House backups that do not invoke a resident model are outside this policy.

## What the evidence can say

OpenAI provides remaining percentages and reset times, not a verified weekly
projection. Compare the lowest applicable allowance for the actual selected model;
do not infer a window duration from its name or reset.

Fresh usage is compared normally. A previous below-threshold reading can still
hold work until its known future provider reset, even if refreshing fails. Other
unknown, malformed or stale data fails open with an unavailable status: missing
usage is not zero remaining. An elapsed reset alone is not proof of recovery.

The owner receives one notice per allowance window rather than one per skipped
tick. No model wake is required to deliver the notice. This policy does not
allocate a shared provider subscription between residents or other clients.

## Recovery and rollout

Turning the brake off restores future scheduled admissions without replaying
skipped rhythm ticks. Held commitments remain inspectable. No existing resident is
enabled automatically. Explain invocation effects and follow the resident
consultation/notice rules in ADR 0002 before enabling affected scope.

The separate **session context budget** is an estimated between-turn rollover
threshold, not a hard within-turn cap. Fresh rhythm conversations and a lower
rollover threshold do not prevent a single turn growing through many tool calls.
See issue #952 for the bounded follow-up.
