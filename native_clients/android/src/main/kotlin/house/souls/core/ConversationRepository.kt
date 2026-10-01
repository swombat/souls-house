package house.souls.core

import java.util.UUID
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

interface ConversationTransport {
    suspend fun changes(conversationId: String, since: Long): ChangesPage
    /** Only an HTTP 200/201 canonical response is acceptance; timeouts throw. */
    suspend fun send(conversationId: String, exactPayload: String): Message
}

data class ConversationState(
    val messages: Map<String, Message> = emptyMap(),
    val cursor: Long = 0,
    val pending: List<OutboxEntry> = emptyList(),
    val sending: Set<UUID> = emptySet(),
    val syncing: Boolean = false,
    val dirty: Boolean = true,
    val loggedOut: Boolean = false,
)

/**
 * Session-owned, one conversation, no UI or network implementation. The mutex
 * protects local transitions; it is never held over transport awaits. A logout
 * closes this instance permanently; reauthentication constructs a fresh scope.
 */
class ConversationRepository(
    private val scope: SessionScope,
    private val conversationId: String,
    private val transport: ConversationTransport,
    private val outbox: OutboxStore,
) {
    private val gate = Mutex()
    private val mutable = MutableStateFlow(ConversationState())
    val state: StateFlow<ConversationState> = mutable.asStateFlow()
    private var generation = 0L

    /** Restore only this login's committed work; restoring does not send it. */
    suspend fun restoreOutbox() = gate.withLock {
        checkActive()
        mutable.value = mutable.value.copy(
            pending = outbox.entries(scope).filter { it.conversationId == conversationId },
        )
    }

    suspend fun submit(content: String, attachments: List<String> = emptyList()): UUID {
        val entry = OutboxEntry.create(conversationId, content, attachments)
        gate.withLock {
            checkActive()
            outbox.put(scope, entry) // Failure exits BEFORE any network call.
            mutable.value = mutable.value.copy(pending = mutable.value.pending + entry)
        }
        retry(entry.id)
        return entry.id
    }

    /** Ambiguous failures leave the exact original entry committed for explicit retry. */
    suspend fun retry(id: UUID) {
        val work = gate.withLock {
            checkActive()
            if (id in mutable.value.sending) return
            val entry = mutable.value.pending.single { it.id == id }
            mutable.value = mutable.value.copy(sending = mutable.value.sending + id)
            generation to entry
        }
        try {
            val accepted = transport.send(conversationId, work.second.payload)
            require(accepted.conversationId == conversationId)
            require(accepted.revision > 0)
            require(accepted.discarded || accepted.clientMessageId == id.toString())
            gate.withLock {
                if (!isCurrent(work.first)) return
                outbox.remove(scope, id) // A failed commit keeps the entry retryable.
                mutable.value = mutable.value.copy(pending = mutable.value.pending.filterNot { it.id == id })
                merge(listOf(accepted))
                // A send response is NOT a complete changes checkpoint.
                mutable.value = mutable.value.copy(dirty = true)
            }
        } finally {
            withContext(NonCancellable) {
                gate.withLock {
                    if (isCurrent(work.first)) mutable.value =
                        mutable.value.copy(sending = mutable.value.sending - id)
                }
            }
        }
    }

    suspend fun invalidate() {
        gate.withLock {
            if (mutable.value.loggedOut) return
            mutable.value = mutable.value.copy(dirty = true)
        }
        reconcile()
    }

    suspend fun reconcile() {
        val epoch = gate.withLock {
            if (mutable.value.loggedOut || mutable.value.syncing) return
            mutable.value = mutable.value.copy(syncing = true)
            generation
        }
        try {
            while (true) {
                val since = gate.withLock {
                    if (!isCurrent(epoch)) return
                    mutable.value = mutable.value.copy(dirty = false)
                    mutable.value.cursor
                }
                val page = transport.changes(conversationId, since)
                validate(page, since)
                val again = gate.withLock {
                    if (!isCurrent(epoch)) return
                    merge(page.changes)
                    mutable.value = mutable.value.copy(cursor = page.nextSince)
                    if (page.hasMore || mutable.value.dirty) true else {
                        // Atomic release: no last invalidation falls between this
                        // decision and clearing the in-flight flag.
                        mutable.value = mutable.value.copy(syncing = false)
                        false
                    }
                }
                if (!again) return
            }
        } catch (failure: Exception) {
            withContext(NonCancellable) {
                gate.withLock {
                    if (isCurrent(epoch)) mutable.value = mutable.value.copy(dirty = true, syncing = false)
                }
            }
            throw failure
        }
    }

    /** History is never a checkpoint and absence is never a removal marker. */
    suspend fun applyHistory(messages: List<Message>) = gate.withLock {
        checkActive()
        require(messages.all { it.conversationId == conversationId && it.revision > 0 })
        merge(messages)
    }

    suspend fun logout() = gate.withLock {
        generation++
        mutable.value = ConversationState(loggedOut = true, dirty = false)
        // Even when cleanup fails, late work cannot apply; caller must surface
        // the cleanup failure. Remote revocation/credential cleanup are deferred.
        outbox.clear(scope)
    }

    private fun merge(messages: List<Message>) {
        val next = mutable.value.messages.toMutableMap()
        messages.forEach { incoming ->
            require(incoming.conversationId == conversationId && incoming.revision > 0)
            if (incoming.revision > (next[incoming.id]?.revision ?: -1)) {
                next[incoming.id] = if (incoming.discarded) Message(
                    incoming.id, incoming.conversationId, incoming.revision, true,
                ) else incoming
            }
        }
        mutable.value = mutable.value.copy(messages = next.toMap())
    }

    private fun validate(page: ChangesPage, since: Long) {
        require(page.nextSince >= since && page.latestRevision >= page.nextSince)
        var previous = since
        page.changes.forEach {
            require(it.conversationId == conversationId && it.revision > previous)
            previous = it.revision
        }
        require(page.nextSince == previous)
        require(!page.hasMore || page.changes.isNotEmpty())
    }

    private fun checkActive() = check(!mutable.value.loggedOut) { "Session closed" }
    private fun isCurrent(epoch: Long) = generation == epoch && !mutable.value.loggedOut
}

/**
 * Lifecycle adapter seam. The host must call tick with monotonic milliseconds at
 * least every 30s, and confirmSubscription only AFTER registering event handling
 * and receiving Cable subscription acknowledgement. No timer/socket is installed.
 */
class ForegroundRepair(private val repository: ConversationRepository) {
    private var foreground = false
    private var online = false
    private var lastRepair: Long? = null

    suspend fun environment(foreground: Boolean, online: Boolean, now: Long) {
        val becameActive = foreground && online && (!this.foreground || !this.online)
        this.foreground = foreground
        this.online = online
        if (becameActive) repair(now)
    }

    suspend fun confirmedSubscription(now: Long) {
        if (foreground && online) repair(now)
    }

    suspend fun tick(now: Long) {
        if (foreground && online && (lastRepair == null || now - lastRepair!! >= 30_000)) repair(now)
    }

    private suspend fun repair(now: Long) {
        lastRepair = now
        repository.invalidate()
    }
}
