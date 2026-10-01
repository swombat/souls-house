import Foundation

/// The platform adapter owns HTTP/auth/status handling. Return bytes only on
/// 200/201 acceptance; ambiguous errors must not imply the message was rejected.
public protocol ConversationTransport: Sendable {
    func changes(conversationID: String, since: Int64) async throws -> Data
    func send(conversationID: String, payload: Data) async throws -> Data
}

public struct Snapshot: Sendable {
    public let cursor: Int64
    public let messages: [String: Message]
    public let pending: [Submission]
    public let active: Bool
}

/// One session/account/conversation scope. Reauthentication creates a NEW core
/// with a NEW sessionID; pending work is never automatically imported.
public actor ConversationCore {
    public let sessionID: UUID
    public let conversationID: String
    private let transport: any ConversationTransport
    private let store: any OutboxStore
    private var generation: UInt64 = 0
    private var active = true
    private var cursor: Int64 = 0
    private var messages: [String: Message] = [:]
    private var dirty = false
    private var fetching = false
    private var sending: Set<UUID> = []
    private var lastRepair: TimeInterval?

    public init(sessionID: UUID, conversationID: String, transport: any ConversationTransport, store: any OutboxStore) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.transport = transport
        self.store = store
    }

    public func snapshot() throws -> Snapshot {
        Snapshot(cursor: cursor, messages: messages,
                 pending: active ? try store.pending(sessionID: sessionID).filter { $0.conversationID == conversationID } : [],
                 active: active)
    }

    /// History is an overlay, never a synchronization checkpoint or evidence
    /// that an absent row was removed. Caller carries the session scope.
    public func applyHistory(_ bytes: Data) throws {
        guard active else { throw CoreError.inactiveSession }
        let page = try Wire.decode(HistoryPage.self, from: bytes)
        for message in page.messages { try validate(message) }
        for message in page.messages { apply(message) }
    }

    public func submit(content: String, attachmentIDs: [String] = [], id: UUID = UUID()) async throws -> UUID {
        guard active else { throw CoreError.inactiveSession }
        let submission = try Submission(sessionID: sessionID, conversationID: conversationID, id: id, content: content, attachmentIDs: attachmentIDs)
        try store.insert(submission) // No await: logout cannot interleave with commit.
        try await retry(id: id)
        return id
    }

    public func retry(id: UUID) async throws {
        guard active else { throw CoreError.inactiveSession }
        guard !sending.contains(id) else { return }
        guard let submission = try store.pending(sessionID: sessionID).first(where: { $0.id == id && $0.conversationID == conversationID }) else {
            throw CoreError.missingSubmission
        }
        sending.insert(id)
        defer { sending.remove(id) }
        let started = generation
        let bytes = try await transport.send(conversationID: conversationID, payload: submission.payload)
        guard active && generation == started else { throw CoreError.inactiveSession }
        let response = try Wire.decode(SendResponse.self, from: bytes)
        try validate(response.message)
        // Kept responses expose our key; markers intentionally don't.
        if !response.message.discarded && response.message.clientMessageID != id.uuidString.lowercased() {
            throw CoreError.identityConflict
        }
        try store.remove(sessionID: sessionID, id: id)
        apply(response.message)
        // Sending/history never advances the authoritative changes checkpoint.
    }

    public func invalidate() async throws {
        guard active else { throw CoreError.inactiveSession }
        dirty = true
        guard !fetching else { return } // In-flight loop owns the dirty follow-up.
        fetching = true
        defer { fetching = false }
        let started = generation
        do {
            repeat {
                dirty = false
                let since = cursor
                let bytes = try await transport.changes(conversationID: conversationID, since: since)
                guard active && generation == started else { throw CoreError.inactiveSession }
                let page = try Wire.decode(ChangesPage.self, from: bytes)
                try validate(page, since: since)
                for message in page.changes { apply(message) }
                cursor = page.nextSince // NEVER latestRevision.
                dirty = dirty || page.hasMore
            } while dirty
        } catch {
            if active { dirty = true }
            throw error
        }
    }

    /// Call after subscription ACK on every (re)connect.
    public func reconnected() async throws { try await invalidate() }
    public func foregrounded(now: TimeInterval) async throws {
        lastRepair = now
        try await invalidate()
    }
    /// Platform lifecycle owner supplies monotonic seconds and calls regularly.
    /// No background/offline polling or unowned timer task.
    public func repairTick(now: TimeInterval, foreground: Bool, online: Bool, onScreen: Bool) async throws {
        guard active && foreground && online && onScreen else { return }
        if lastRepair == nil || now - lastRepair! >= 30 {
            lastRepair = now
            try await invalidate()
        }
    }

    public func logout() throws {
        active = false
        generation &+= 1
        dirty = false
        messages = [:]
        cursor = 0
        // Even if cleanup fails, this core stays inactive. Surface failure for
        // platform cleanup retry; never claim remote revocation succeeded.
        try store.clear(sessionID: sessionID)
    }

    private func validate(_ message: Message) throws {
        guard message.conversationID == conversationID else { throw CoreError.wrongConversation }
        guard message.revision > 0 else { throw CoreError.invalidPage }
    }
    private func validate(_ page: ChangesPage, since: Int64) throws {
        guard page.nextSince >= since && page.latestRevision >= page.nextSince else { throw CoreError.invalidPage }
        var last = since
        for message in page.changes {
            try validate(message)
            guard message.revision > last else { throw CoreError.invalidPage }
            last = message.revision
        }
        guard page.nextSince == last && (!page.hasMore || !page.changes.isEmpty) else { throw CoreError.invalidPage }
    }
    private func apply(_ message: Message) {
        guard message.revision > (messages[message.id]?.revision ?? 0) else { return }
        messages[message.id] = message
    }
}
