package house.souls.core

import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ConversationRepositoryTest {
    private val scope = SessionScope("account_demo", "login_demo")
    private val conversation = "conv_demo"
    private val fixtureId = UUID.fromString("11111111-2222-4333-8444-555555555555")
    private fun fixture(name: String) = Files.readString(Path.of("../fixtures/$name.json"))
    private fun page(name: String) = Wire.changes(fixture(name))
    private fun message(revision: Long, discarded: Boolean = false, id: String = "m") =
        Message(id, conversation, revision, discarded, MessageRole.USER, if (discarded) null else "body", true)

    private class Transport : ConversationTransport {
        val cursors = mutableListOf<Long>()
        val payloads = mutableListOf<String>()
        var fetch: suspend (Long) -> ChangesPage = { ChangesPage(emptyList(), it, false, it) }
        var post: suspend (String) -> Message = { error("No send expected") }
        override suspend fun changes(conversationId: String, since: Long): ChangesPage {
            cursors += since
            return fetch(since)
        }
        override suspend fun send(conversationId: String, exactPayload: String): Message {
            payloads += exactPayload
            return post(exactPayload)
        }
    }

    private fun repository(transport: Transport, store: OutboxStore = InMemoryOutboxStore()) =
        ConversationRepository(scope, conversation, transport, store)

    @Test fun `shared fixtures page at next_since not advertised head and keep discard over history`() = runTest {
        val transport = Transport()
        transport.fetch = { since ->
            when (since) {
                0L -> page("changes-first")
                4L -> page("changes-discard")
                else -> page("changes-empty")
            }
        }
        val repo = repository(transport)
        repo.reconcile()
        assertEquals(listOf(0L, 4L), transport.cursors)
        assertEquals(9, repo.state.value.cursor)
        repo.applyHistory(Wire.history(fixture("history-stale")))
        assertTrue(repo.state.value.messages.getValue("msg_alpha").discarded)
        assertNull(repo.state.value.messages.getValue("msg_alpha").content)
        assertEquals(2, repo.state.value.messages.size) // absence does not delete beta
        repo.reconcile()
        assertEquals(9, repo.state.value.cursor)
    }

    @Test fun `unknown fields and role tolerated but cannot grant authority and timestamps keep precision`() {
        val future = page("changes-unknown").changes.single()
        assertEquals(MessageRole.UNKNOWN, future.role)
        assertEquals(AuthorType.UNKNOWN, future.authorType)
        assertFalse(future.isOwnModifiableHumanMessage("user_demo"))
        val accepted = Wire.acceptance(fixture("send-accepted"))
        assertEquals(fixtureId, UUID.fromString(accepted.clientMessageId))
        assertEquals(Instant.parse("2026-10-01T12:00:00.123456Z"), accepted.createdAt)
        assertEquals(123456000, accepted.createdAt!!.nano)
        assertTrue(accepted.isOwnModifiableHumanMessage("user_demo"))
        assertFalse(accepted.copy(authorType = AuthorType.UNKNOWN).isOwnModifiableHumanMessage("user_demo"))
        val marker = Wire.acceptance(fixture("send-discarded"))
        assertNull(marker.content)
        assertNull(marker.createdAt)
    }

    @Test fun `signed bigint and malformed required fields fail closed`() {
        assertEquals(Long.MAX_VALUE, Wire.changes(
            """{"changes":[],"next_since":9223372036854775807,"has_more":false,"latest_revision":0}"""
        ).nextSince)
        for (invalid in listOf("-1", "9223372036854775808", "1.5", "\"1\"")) {
            assertFails { Wire.changes("""{"changes":[],"next_since":$invalid,"has_more":false,"latest_revision":0}""") }
        }
        assertFails { Wire.changes("""{"changes":[],"next_since":0,"latest_revision":0}""") }
    }

    @Test fun `ambiguous delivery restores immutable bytes and accepted retry does not advance checkpoint`() = runTest {
        val store = InMemoryOutboxStore()
        val entry = OutboxEntry(fixtureId, conversation, fixture("send-request"))
        store.put(scope, entry)
        val transport = Transport()
        transport.post = { throw IllegalStateException("response lost") }
        val first = repository(transport, store)
        first.restoreOutbox()
        assertFailsWith<IllegalStateException> { first.retry(entry.id) }
        assertEquals(listOf(entry), store.entries(scope))
        val restored = repository(transport, store)
        restored.restoreOutbox()
        transport.post = { Wire.acceptance(fixture("send-accepted")) }
        restored.retry(entry.id)
        assertEquals(listOf(entry.payload, entry.payload), transport.payloads)
        assertTrue(store.entries(scope).isEmpty())
        assertTrue(restored.state.value.pending.isEmpty())
        assertEquals(0, restored.state.value.cursor)
        assertEquals("Hello, native clients.", restored.state.value.messages.getValue("msg_alpha").content)
    }

    @Test fun `discarded retry is accepted without body resurrection`() = runTest {
        val store = InMemoryOutboxStore()
        val entry = OutboxEntry(fixtureId, conversation, fixture("send-request"))
        store.put(scope, entry)
        val transport = Transport().also { it.post = { Wire.acceptance(fixture("send-discarded")) } }
        val repo = repository(transport, store)
        repo.restoreOutbox()
        repo.retry(entry.id)
        repo.applyHistory(Wire.history(fixture("history-stale")))
        assertTrue(repo.state.value.messages.getValue("msg_alpha").discarded)
        assertTrue(repo.state.value.pending.isEmpty())
    }

    @Test fun `persist failure prevents send and immutable identity rejects mutation`() = runTest {
        val fake = InMemoryOutboxStore()
        val broken = object : OutboxStore by fake {
            override suspend fun put(scope: SessionScope, entry: OutboxEntry) { error("disk full") }
        }
        val transport = Transport()
        assertFailsWith<IllegalStateException> { repository(transport, broken).submit("exact\nbody") }
        assertTrue(transport.payloads.isEmpty())
        val entry = OutboxEntry.create(conversation, "unchanged", listOf("upload-b", "upload-a"))
        fake.put(scope, entry)
        assertFailsWith<IllegalArgumentException> { fake.put(scope, entry.copy(payload = "changed")) }
        assertTrue(entry.payload.indexOf("upload-b") < entry.payload.indexOf("upload-a"))
    }

    @Test fun `submit commits before transport and double retry coalesces`() = runTest {
        val store = InMemoryOutboxStore()
        val entered = CompletableDeferred<UUID>()
        val response = CompletableDeferred<Message>()
        val transport = Transport()
        transport.post = {
            val committed = store.entries(scope).single()
            assertEquals(committed.payload, it)
            entered.complete(committed.id)
            response.await()
        }
        val repo = repository(transport, store)
        val submit = async { repo.submit("body") }
        val id = entered.await()
        repo.retry(id)
        assertEquals(1, transport.payloads.size)
        response.complete(message(3).copy(clientMessageId = id.toString()))
        assertEquals(id, submit.await())
        assertTrue(repo.state.value.pending.isEmpty())
    }

    @Test fun `logout drops late fetch and send and isolates new login`() = runTest {
        val store = InMemoryOutboxStore()
        val fetchReply = CompletableDeferred<ChangesPage>()
        val sendReply = CompletableDeferred<Message>()
        val transport = Transport().also {
            it.fetch = { fetchReply.await() }
            it.post = { sendReply.await() }
        }
        val repo = repository(transport, store)
        val fetch = launch { repo.reconcile() }
        val send = async { repo.submit("body") }
        runCurrent()
        val id = repo.state.value.pending.single().id
        repo.logout()
        fetchReply.complete(ChangesPage(listOf(message(2)), 2, false, 2))
        sendReply.complete(message(3).copy(clientMessageId = id.toString()))
        fetch.join()
        send.await()
        assertTrue(repo.state.value.loggedOut)
        assertTrue(repo.state.value.messages.isEmpty())
        assertTrue(store.entries(scope).isEmpty())
        val fresh = ConversationRepository(scope.copy(loginId = "new_login"), conversation, transport, store)
        fresh.restoreOutbox()
        assertTrue(fresh.state.value.pending.isEmpty())
        assertFailsWith<IllegalStateException> { repo.submit("cannot send") }
    }

    @Test fun `invalidations during fetch require follow-up and bursts coalesce`() = runTest {
        val reply = CompletableDeferred<ChangesPage>()
        val transport = Transport()
        transport.fetch = { since ->
            if (transport.cursors.size == 1) reply.await() else ChangesPage(emptyList(), since, false, since)
        }
        val repo = repository(transport)
        val fetch = launch { repo.reconcile() }
        runCurrent()
        repeat(5) { repo.invalidate() }
        reply.complete(ChangesPage(listOf(message(2)), 2, false, 2))
        fetch.join()
        assertEquals(listOf(0L, 2L), transport.cursors)
        assertFalse(repo.state.value.dirty)
        assertFalse(repo.state.value.syncing)
    }

    @Test fun `foreground confirmed reconnect and bounded thirty second repair triggers`() = runTest {
        val transport = Transport()
        val repair = ForegroundRepair(repository(transport))
        repair.environment(false, true, 0)
        repair.tick(30_000)
        assertTrue(transport.cursors.isEmpty())
        repair.environment(true, true, 40_000)
        repair.tick(69_999)
        assertEquals(1, transport.cursors.size)
        repair.tick(70_000)
        repair.confirmedSubscription(71_000)
        assertEquals(3, transport.cursors.size)
        repair.environment(true, false, 72_000)
        repair.tick(200_000)
        assertEquals(3, transport.cursors.size)
        repair.environment(true, true, 201_000)
        assertEquals(4, transport.cursors.size)
    }

    @Test fun `cancellation clears flight flags and remains repairable`() = runTest {
        val blocked = CompletableDeferred<ChangesPage>()
        val transport = Transport().also { it.fetch = { blocked.await() } }
        val repo = repository(transport)
        val job = launch { repo.reconcile() }
        runCurrent()
        job.cancel()
        job.join()
        assertFalse(repo.state.value.syncing)
        assertTrue(repo.state.value.dirty)
        transport.fetch = { ChangesPage(emptyList(), it, false, it) }
        repo.reconcile()
        assertFalse(repo.state.value.dirty)
    }

    @Test fun `failed acceptance cleanup keeps original payload retryable`() = runTest {
        val fake = InMemoryOutboxStore()
        val store = object : OutboxStore by fake {
            override suspend fun remove(scope: SessionScope, id: UUID) { error("disk unavailable") }
        }
        val entry = OutboxEntry(fixtureId, conversation, fixture("send-request"))
        store.put(scope, entry)
        val transport = Transport().also { it.post = { Wire.acceptance(fixture("send-accepted")) } }
        val repo = repository(transport, store)
        repo.restoreOutbox()
        assertFailsWith<IllegalStateException> { repo.retry(entry.id) }
        assertEquals(listOf(entry), repo.state.value.pending)
        assertTrue(repo.state.value.sending.isEmpty())
        assertTrue(repo.state.value.messages.isEmpty())
    }

    @Test fun `cancelled send clears flight and original entry can retry`() = runTest {
        val fake = InMemoryOutboxStore()
        val storeEntered = CompletableDeferred<Unit>()
        val releaseStore = CompletableDeferred<Unit>()
        var holdReads = false
        val store = object : OutboxStore by fake {
            override suspend fun entries(scope: SessionScope): List<OutboxEntry> {
                if (holdReads) {
                    storeEntered.complete(Unit)
                    releaseStore.await()
                }
                return fake.entries(scope)
            }
        }
        val entry = OutboxEntry(fixtureId, conversation, fixture("send-request"))
        store.put(scope, entry)
        val blocked = CompletableDeferred<Message>()
        val transport = Transport().also { it.post = { blocked.await() } }
        val repo = repository(transport, store)
        repo.restoreOutbox()
        val job = launch { repo.retry(entry.id) }
        runCurrent()
        holdReads = true
        val restore = launch { repo.restoreOutbox() }
        storeEntered.await() // Gate held while send cancellation tries cleanup.
        job.cancel()
        runCurrent()
        assertTrue(job.isActive.not())
        releaseStore.complete(Unit)
        restore.join()
        job.join()
        assertTrue(repo.state.value.sending.isEmpty())
        assertEquals(listOf(entry), repo.state.value.pending)
        transport.post = { Wire.acceptance(fixture("send-accepted")) }
        repo.retry(entry.id)
        assertTrue(repo.state.value.pending.isEmpty())
    }

    @Test fun `malformed transport acceptance cannot erase pending and invalid page cannot advance`() = runTest {
        val store = InMemoryOutboxStore()
        val entry = OutboxEntry(fixtureId, conversation, fixture("send-request"))
        store.put(scope, entry)
        val transport = Transport().also {
            it.post = { Wire.acceptance(fixture("send-accepted")).copy(revision = 0) }
            it.fetch = { ChangesPage(listOf(message(2)), 2, false, 1) }
        }
        val repo = repository(transport, store)
        repo.restoreOutbox()
        assertFailsWith<IllegalArgumentException> { repo.retry(entry.id) }
        assertEquals(listOf(entry), store.entries(scope))
        assertFailsWith<IllegalArgumentException> { repo.reconcile() }
        assertEquals(0, repo.state.value.cursor)
        assertFailsWith<IllegalArgumentException> { repo.applyHistory(listOf(message(0))) }
        assertTrue(repo.state.value.messages.isEmpty())
    }
}
