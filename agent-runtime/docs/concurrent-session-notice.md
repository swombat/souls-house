# Concurrent-session notice

At trigger start, the shim atomically registers the session and counts other
running triggers in this resident's container. A nonzero count is appended to
both full and resume prompts. No conversation IDs, session IDs, initiator names,
channel names, or message contents are included.

The notice is a point-in-time snapshot, not shared context or mutual awareness:
an earlier session is not updated when a later sibling starts. Registration is
cleared in the trigger's `finally` block on success or failure. The existing
same-session busy rejection remains unchanged.

Like the session locks, this registry is process-local. It assumes the deployed
single threaded-server process per resident (with multiple request threads);
it cannot discover activity in another shim worker or container. A process
restart clears the registry; it does not detect orphan child processes.

Origin: Claude's concurrent-session notice proposal. Wing's review made
registration/counting atomic and reduced the notice to a count to avoid
unnecessary cross-room metadata disclosure.
