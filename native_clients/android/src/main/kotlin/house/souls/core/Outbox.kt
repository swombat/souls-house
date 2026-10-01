package house.souls.core

import java.util.UUID

/** A scope includes a fresh login identity, not just an account identifier. */
data class SessionScope(val accountId: String, val loginId: String)

/** Strings keep exact immutable request bytes and attachment ordering across retries. */
data class OutboxEntry(val id: UUID, val conversationId: String, val payload: String) {
    companion object {
        fun create(conversationId: String, content: String, attachments: List<String>): OutboxEntry {
            require(content.isNotBlank() || attachments.isNotEmpty())
            require(attachments.size <= 10)
            val id = UUID.randomUUID()
            return OutboxEntry(id, conversationId, Wire.submission(id.toString(), content, attachments))
        }
    }
}

/**
 * Production implementations must commit atomically before returning. put is
 * insert-only (an identical retry is allowed); a UUID cannot change payload.
 * Storage is session scoped; a new login never automatically adopts old work.
 */
interface OutboxStore {
    suspend fun entries(scope: SessionScope): List<OutboxEntry>
    suspend fun put(scope: SessionScope, entry: OutboxEntry)
    suspend fun remove(scope: SessionScope, id: UUID)
    suspend fun clear(scope: SessionScope)
}

/** Explicit fake, NOT durable storage or process-death evidence. */
class InMemoryOutboxStore : OutboxStore {
    private val rows = mutableMapOf<SessionScope, MutableMap<UUID, OutboxEntry>>()

    override suspend fun entries(scope: SessionScope): List<OutboxEntry> =
        synchronized(rows) { rows[scope]?.values?.toList().orEmpty() }

    override suspend fun put(scope: SessionScope, entry: OutboxEntry) {
        synchronized(rows) {
            val scoped = rows.getOrPut(scope) { linkedMapOf() }
            val existing = scoped[entry.id]
            require(existing == null || existing == entry) { "Immutable submission identity" }
            scoped[entry.id] = entry
        }
    }

    override suspend fun remove(scope: SessionScope, id: UUID) {
        synchronized(rows) { rows[scope]?.remove(id) }
    }

    override suspend fun clear(scope: SessionScope) {
        synchronized(rows) { rows.remove(scope) }
    }
}
