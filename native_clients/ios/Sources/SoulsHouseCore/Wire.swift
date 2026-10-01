import Foundation

public enum CoreError: Error, Equatable {
    case invalidPage, wrongConversation, inactiveSession, missingSubmission, identityConflict
}

public enum Wire {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid API date"))
        }
        return try decoder.decode(type, from: data)
    }
}

public struct Author: Decodable, Sendable, Equatable {
    public let type: String
    public let id: String?
    public let name: String
}

public struct Attachment: Decodable, Sendable, Equatable {
    public let id: Int64
    public let filename: String
    public let contentType: String?
    public let byteSize: Int64
    public let downloadPath: String
    enum CodingKeys: String, CodingKey {
        case id, filename
        case contentType = "content_type", byteSize = "byte_size", downloadPath = "download_path"
    }
}

/// Unknown role/author values are preserved, but never confer permission.
/// Discard markers intentionally drop even unexpected content fields.
public struct Message: Decodable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public let revision: Int64
    public let discarded: Bool
    public let role: String?
    public let author: Author?
    public let content: String?
    public let completed: Bool?
    public let attachments: [Attachment]
    public let clientMessageID: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, revision, discarded, role, author, content, completed, attachments
        case conversationID = "conversation_id", clientMessageID = "client_message_id"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        revision = try c.decode(Int64.self, forKey: .revision)
        discarded = try c.decode(Bool.self, forKey: .discarded)
        if discarded {
            role = nil; author = nil; content = nil; completed = nil
            attachments = []; clientMessageID = nil; createdAt = nil; updatedAt = nil
        } else {
            role = try c.decode(String.self, forKey: .role)
            author = try c.decode(Author.self, forKey: .author)
            content = try c.decode(String.self, forKey: .content)
            completed = try c.decode(Bool.self, forKey: .completed)
            attachments = try c.decode([Attachment].self, forKey: .attachments)
            clientMessageID = try c.decodeIfPresent(String.self, forKey: .clientMessageID)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        }
    }

    public func mayModify(viewerID: String) -> Bool {
        !discarded && role == "user" && author?.type == "human" && author?.id == viewerID
    }
}

public struct ChangesPage: Decodable, Sendable {
    public let changes: [Message]
    public let nextSince: Int64
    public let hasMore: Bool
    public let latestRevision: Int64
    enum CodingKeys: String, CodingKey {
        case changes
        case nextSince = "next_since", hasMore = "has_more", latestRevision = "latest_revision"
    }
}

public struct SendResponse: Decodable, Sendable {
    public let message: Message
    // Dispatch is not message acceptance or proof that a resident started.
}

public struct HistoryPage: Decodable, Sendable {
    public let messages: [Message]
}
