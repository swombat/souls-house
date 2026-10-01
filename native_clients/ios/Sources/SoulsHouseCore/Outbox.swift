import Foundation

public struct Submission: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let conversationID: String
    public let id: UUID
    /// Encode once, store before delivery, reuse these exact bytes on retry.
    public let payload: Data

    public init(sessionID: UUID, conversationID: String, id: UUID, content: String, attachmentIDs: [String] = []) throws {
        struct Payload: Encodable {
            let client_message_id: String
            let content: String
            let attachment_ids: [String]?
        }
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.id = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        payload = try encoder.encode(Payload(
            client_message_id: id.uuidString.lowercased(), content: content,
            attachment_ids: attachmentIDs.isEmpty ? nil : attachmentIDs
        ))
    }
}

/// Synchronous, transactional local seam: success means committed, failure means
/// no change. insert rejects changed identity/payload; accepted removal is atomic.
/// A production adapter must serialize access and provide durable commits.
public protocol OutboxStore: Sendable {
    func insert(_ submission: Submission) throws
    func pending(sessionID: UUID) throws -> [Submission]
    func remove(sessionID: UUID, id: UUID) throws
    func clear(sessionID: UUID) throws
}

/// TEST FAKE ONLY — memory is not durable storage.
public final class InMemoryOutboxStore: OutboxStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UUID: [UUID: Submission]] = [:]
    public init() {}
    public func insert(_ submission: Submission) throws {
        lock.lock(); defer { lock.unlock() }
        if let existing = rows[submission.sessionID]?[submission.id], existing != submission {
            throw CoreError.identityConflict
        }
        rows[submission.sessionID, default: [:]][submission.id] = submission
    }
    public func pending(sessionID: UUID) throws -> [Submission] {
        lock.lock(); defer { lock.unlock() }
        return Array(rows[sessionID, default: [:]].values).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func remove(sessionID: UUID, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        rows[sessionID]?[id] = nil
    }
    public func clear(sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        rows[sessionID] = nil
    }
}
