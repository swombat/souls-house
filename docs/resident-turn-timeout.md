# Resident turn timeout

Resident Settings → **Turn timeout (minutes)** controls one trigger's elapsed
execution budget, including model calls and tools. It defaults to 30 minutes,
accepts whole minutes from 1 to 1440 (24 hours), and takes effect on the next
trigger. Existing residents retain 30 minutes; changing it does not extend an
already running turn or automatically retry failed work.

The setting applies to conversation, Telegram, heartbeat, orientation and memory
aggregation triggers. It is distinct from session idle/max-age thresholds, which
decide when to start a fresh context between turns.

Rails sends the resident's budget with each trigger and allows an additional
30 seconds for the HTTP response and live-activity reporting. The shim shares a
monotonic deadline across resume and fresh-fallback invocations. Gemini
subscription calls derive `CHAOS_AGY_PRINT_TIMEOUT_SECONDS` from the remaining
budget, reserving 35 seconds for Chaos's transport grace and reporting instead
of silently using Antigravity's five-minute default. Direct API calls and other
providers are not given an Antigravity override.

Deploy both the Rails migration/application and updated resident runtime image.
Updating only Rails cannot remove the old runtime's Antigravity limit or make
its resume/fallback attempts share a budget. Existing resident containers must
receive the updated runtime through the normal idle-safe reconciliation process.
No Chaos rebuild or provider reauthentication is needed for this setting.

This is a maximum, not a promise of uninterrupted execution: provider limits,
host failures and runtime replacement can still end a turn earlier. Long turns
also occupy a job worker while the synchronous trigger request is in flight.
Raising this setting does not make work durable across deployments or restarts.
