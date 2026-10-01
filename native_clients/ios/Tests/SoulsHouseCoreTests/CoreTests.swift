import Foundation
import Testing
@testable import SoulsHouseCore

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("fixtures/\(name).json"))
}

private enum SyntheticFailure: Error { case offline, storage }

private actor FakeTransport: ConversationTransport {
    var pages: [Data]
    var sends: [Data] = []
    var cursors: [Int64] = []
    var response: Data
    var failSend = false
    var holdFetch = false
    var holdSend = false
    var gate: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?

    init(pages: [Data] = [], response: Data = Data()) {
        self.pages = pages; self.response = response
    }
    func configure(fetch: Bool = false, send: Bool = false, failure: Bool = false) {
        holdFetch = fetch; holdSend = send; failSend = failure
    }
    func waitForRequest() async {
        if gate != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() {
        gate?.resume(); gate = nil; holdFetch = false; holdSend = false
    }
    private func pause() async {
        await withCheckedContinuation { continuation in
            gate = continuation
            entered?.resume(); entered = nil
        }
    }
    func changes(conversationID: String, since: Int64) async throws -> Data {
        cursors.append(since)
        if holdFetch { await pause() }
        if pages.isEmpty { throw SyntheticFailure.offline }
        return pages.removeFirst()
    }
    func send(conversationID: String, payload: Data) async throws -> Data {
        sends.append(payload)
        if holdSend { await pause() }
        if failSend { throw SyntheticFailure.offline }
        return response
    }
}

private struct FailingStore: OutboxStore {
    func insert(_ submission: Submission) throws { throw SyntheticFailure.storage }
    func pending(sessionID: UUID) throws -> [Submission] { [] }
    func remove(sessionID: UUID, id: UUID) throws {}
    func clear(sessionID: UUID) throws {}
}

private struct RemovalFailingStore: OutboxStore {
    let backing = InMemoryOutboxStore()
    func insert(_ submission: Submission) throws { try backing.insert(submission) }
    func pending(sessionID: UUID) throws -> [Submission] { try backing.pending(sessionID: sessionID) }
    func remove(sessionID: UUID, id: UUID) throws { throw SyntheticFailure.storage }
    func clear(sessionID: UUID) throws { throw SyntheticFailure.storage }
}

private let key = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
private func core(_ transport: FakeTransport, store: any OutboxStore = InMemoryOutboxStore(), session: UUID = UUID()) -> ConversationCore {
    ConversationCore(sessionID: session, conversationID: "conv_demo", transport: transport, store: store)
}

@Test func fixtureDatesUnknownAndDiscardSafety() throws {
    let first = try Wire.decode(ChangesPage.self, from: fixture("changes-first"))
    #expect(first.nextSince == 4 && first.latestRevision == 9)
    let message = first.changes[0]
    #expect(message.createdAt != nil && message.updatedAt! > message.createdAt!)
    #expect(message.mayModify(viewerID: "user_demo"))
    #expect(!message.mayModify(viewerID: "someone_else"))
    #expect(UUID(uuidString: message.clientMessageID!) == key)
    let unknown = try Wire.decode(ChangesPage.self, from: fixture("changes-unknown")).changes[0]
    #expect(!unknown.mayModify(viewerID: "user_demo"))
    let marker = try Wire.decode(SendResponse.self, from: fixture("send-discarded")).message
    #expect(marker.discarded && marker.content == nil && marker.attachments.isEmpty)
}

@Test func cursorAndStaleHistory() async throws {
    let transport = FakeTransport(pages: [try fixture("changes-first"), try fixture("changes-discard"), try fixture("changes-empty")])
    let repository = core(transport)
    try await repository.invalidate()
    #expect(await transport.cursors == [0, 4])
    var snapshot = try await repository.snapshot()
    #expect(snapshot.cursor == 9)
    #expect(snapshot.messages["msg_alpha"]?.discarded == true)
    try await repository.applyHistory(fixture("history-stale"))
    try await repository.invalidate()
    snapshot = try await repository.snapshot()
    #expect(snapshot.cursor == 9 && snapshot.messages["msg_alpha"]?.content == nil)
    #expect(snapshot.messages["msg_beta"] != nil) // Absence is not removal.
}

@Test func dirtyDuringFetchIsNotLost() async throws {
    let transport = FakeTransport(pages: [try fixture("changes-discard"), try fixture("changes-empty")])
    await transport.configure(fetch: true)
    let repository = core(transport)
    let task = Task { try await repository.invalidate() }
    await transport.waitForRequest()
    try await repository.invalidate()
    await transport.resume()
    try await task.value
    #expect(await transport.cursors == [0, 9])
}

@Test func persistenceFailurePreventsSend() async throws {
    let transport = FakeTransport(response: try fixture("send-accepted"))
    let repository = core(transport, store: FailingStore())
    await #expect(throws: SyntheticFailure.self) { try await repository.submit(content: "Hello", id: key) }
    #expect(await transport.sends.isEmpty)
}

@Test func ambiguousRetryUsesPersistedExactPayloadAfterRecreation() async throws {
    let transport = FakeTransport(response: try fixture("send-accepted"))
    await transport.configure(failure: true)
    let store = InMemoryOutboxStore()
    let session = UUID()
    let repository = core(transport, store: store, session: session)
    await #expect(throws: SyntheticFailure.self) {
        try await repository.submit(content: "Hello, native clients.", id: key)
    }
    let pending = try store.pending(sessionID: session)
    #expect(pending.count == 1 && pending[0].id == key)
    let encoded = try JSONSerialization.jsonObject(with: pending[0].payload) as! NSDictionary
    let request = try JSONSerialization.jsonObject(with: fixture("send-request")) as! NSDictionary
    #expect(encoded == request)
    let restored = try JSONDecoder().decode(Submission.self, from: JSONEncoder().encode(pending[0]))
    #expect(restored == pending[0])
    #expect(throws: CoreError.identityConflict) {
        try store.insert(Submission(sessionID: session, conversationID: "conv_demo", id: key, content: "changed"))
    }
    await transport.configure()
    let recreated = core(transport, store: store, session: session)
    try await recreated.retry(id: key)
    #expect(await transport.sends == [pending[0].payload, pending[0].payload])
    let snapshot = try await recreated.snapshot()
    #expect(snapshot.pending.isEmpty && snapshot.cursor == 0 && snapshot.messages["msg_alpha"] != nil)
}

@Test func discardedRetryIsAcceptanceNotResurrection() async throws {
    let transport = FakeTransport(response: try fixture("send-discarded"))
    let repository = core(transport)
    _ = try await repository.submit(content: "Hello, native clients.", id: key)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.pending.isEmpty && snapshot.messages["msg_alpha"]?.discarded == true)
}

@Test func logoutProtectsLateFetch() async throws {
    let transport = FakeTransport(pages: [try fixture("changes-discard")])
    await transport.configure(fetch: true)
    let repository = core(transport)
    let task = Task { try await repository.invalidate() }
    await transport.waitForRequest()
    try await repository.logout()
    await transport.resume()
    await #expect(throws: CoreError.inactiveSession) { try await task.value }
    let snapshot = try await repository.snapshot()
    #expect(!snapshot.active && snapshot.messages.isEmpty && snapshot.cursor == 0)
}

@Test func logoutProtectsLateSendAndSeparatesSessions() async throws {
    let transport = FakeTransport(response: try fixture("send-accepted"))
    await transport.configure(send: true)
    let store = InMemoryOutboxStore()
    let repository = core(transport, store: store)
    let task = Task { try await repository.submit(content: "Hello, native clients.", id: key) }
    await transport.waitForRequest()
    #expect(try await repository.snapshot().pending.count == 1) // Stored BEFORE send.
    try await repository.logout()
    await transport.resume()
    await #expect(throws: CoreError.inactiveSession) { try await task.value }
    #expect(try await repository.snapshot().messages.isEmpty)
    let replacement = core(transport, store: store)
    #expect(try await replacement.snapshot().pending.isEmpty)
    await #expect(throws: CoreError.missingSubmission) { try await replacement.retry(id: key) }
}

@Test func foregroundReconnectAndThirtySecondRepair() async throws {
    let transport = FakeTransport(pages: [try fixture("changes-discard")] + Array(repeating: try fixture("changes-empty"), count: 3))
    let repository = core(transport)
    try await repository.foregrounded(now: 0)
    try await repository.repairTick(now: 29, foreground: true, online: true, onScreen: true)
    #expect(await transport.cursors.count == 1)
    try await repository.repairTick(now: 30, foreground: true, online: true, onScreen: true)
    try await repository.repairTick(now: 60, foreground: true, online: false, onScreen: true)
    #expect(await transport.cursors.count == 2)
    try await repository.reconnected()
    try await repository.foregrounded(now: 61)
    #expect(await transport.cursors == [0, 9, 9, 9])
}

@Test func invalidPageDoesNotPartiallyApply() async throws {
    let malformed = Data(#"{"changes":[],"next_since":9,"latest_revision":9,"has_more":false}"#.utf8)
    let transport = FakeTransport(pages: [malformed])
    let repository = core(transport)
    await #expect(throws: CoreError.invalidPage) { try await repository.invalidate() }
    #expect(try await repository.snapshot().cursor == 0)

    // A valid first row must not be applied if a later row is invalid.
    var object = try JSONSerialization.jsonObject(with: fixture("changes-first")) as! [String: Any]
    var rows = object["changes"] as! [[String: Any]]
    rows[1]["conversation_id"] = "another_conversation"
    object["changes"] = rows
    let partial = core(FakeTransport(pages: [try JSONSerialization.data(withJSONObject: object)]))
    await #expect(throws: CoreError.wrongConversation) { try await partial.invalidate() }
    #expect(try await partial.snapshot().messages.isEmpty)
}

@Test func staleSendResponseCannotOverwriteNewerDiscard() async throws {
    let transport = FakeTransport(pages: [try fixture("changes-discard")], response: try fixture("send-accepted"))
    let repository = core(transport)
    try await repository.invalidate()
    _ = try await repository.submit(content: "Hello, native clients.", id: key)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.pending.isEmpty && snapshot.cursor == 9)
    #expect(snapshot.messages["msg_alpha"]?.discarded == true)
}

@Test func snapshotDoesNotExposeOtherConversationOrSessionOutbox() async throws {
    let store = InMemoryOutboxStore()
    let session = UUID()
    try store.insert(Submission(sessionID: session, conversationID: "other", id: key, content: "private"))
    try store.insert(Submission(sessionID: UUID(), conversationID: "conv_demo", id: key, content: "private"))
    let repository = core(FakeTransport(), store: store, session: session)
    #expect(try await repository.snapshot().pending.isEmpty)
    let other = ConversationCore(sessionID: session, conversationID: "other", transport: FakeTransport(), store: store)
    #expect(try await other.snapshot().pending.count == 1)
    await #expect(throws: CoreError.missingSubmission) { try await repository.retry(id: key) }
}

@Test func acknowledgementFailureKeepsPendingAndLogoutFailureStillInvalidates() async throws {
    let transport = FakeTransport(response: try fixture("send-accepted"))
    let repository = core(transport, store: RemovalFailingStore())
    await #expect(throws: SyntheticFailure.self) {
        try await repository.submit(content: "Hello, native clients.", id: key)
    }
    let snapshot = try await repository.snapshot()
    #expect(snapshot.pending.count == 1 && snapshot.messages.isEmpty)
    await #expect(throws: SyntheticFailure.self) { try await repository.logout() }
    #expect(try await repository.snapshot().active == false)
    await #expect(throws: CoreError.inactiveSession) { try await repository.retry(id: key) }
}

@Test func unexpectedErrorEnvelopeCannotBecomeAcceptance() async throws {
    // A real adapter throws for 409. Even a misrouted error envelope cannot ack.
    let transport = FakeTransport(response: try fixture("send-conflict"))
    let repository = core(transport)
    await #expect(throws: DecodingError.self) {
        try await repository.submit(content: "Hello, native clients.", id: key)
    }
    #expect(try await repository.snapshot().pending.count == 1)
}
