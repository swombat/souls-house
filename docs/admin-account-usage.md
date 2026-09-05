# Account usage overview

Site admins can select an account at `/admin/accounts` to inspect:

- Agent configuration, runtime/health, heartbeat cadence, conversation participation,
  session counts, tool/voice configuration, subscription authentication and service grants.
- Account service connections, legacy GitHub/X/Oura integrations and AI-key presence.
  Credentials, prompts, message bodies and runtime output are not included in this report.
- Thirty UTC days of daily active sessions, trigger attempts or new conversations.
- The ten most recently active runtime sessions and ten most recently updated conversations.

## Counting semantics

Conversations are account chats, including archived and soft-deleted records. Per-agent
conversation counts are participation records, so a shared chat counts for each participant
but only once in the account total.

Runtime sessions are grouped by agent and logical `session_id`, matching the resident
session monitor. Missing session IDs fall back to individual interactions. Busy retries
(`409 / already_running`) count as attempts but not sessions. Daily session counts describe
sessions active that day; a persistent session can appear on multiple days. Inline agents
can have conversations without any hosted runtime telemetry.

## Storage

Deploy the `AddStorageUsageToAgents` migration. The production recurring schedule queues
measurements hourly at minute 45. Admins can also use **Measure storage**, then **Refresh
overview** once background jobs finish.

Measurements inspect the five persistent Docker volumes (identity, Chaos home, repository,
work and state). A restricted BusyBox helper mounts existing volumes read-only with no
network and runs bounded `du -sk`. It does not start or execute code in the agent container.
The provisioning Docker daemon must be reachable by the worker; the helper image
`busybox:1.37` must be present or pullable. Agents assigned to another sandbox host are
reported unavailable rather than inspecting a different host's data.

Reported bytes are allocated disk blocks, not a quota. Shared images, container writable
layers, logs outside these volumes, Rails database records and remote backups are excluded.
Missing volumes produce a partial measurement, not invented zeroes. Failed measurements
retain any previous reading and its timestamp while marking it unavailable. Readings older
than two hours are labelled stale. Totals identify incomplete/outdated measurements.
