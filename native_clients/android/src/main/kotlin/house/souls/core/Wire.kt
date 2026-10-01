package house.souls.core

import kotlinx.serialization.json.*
import java.time.Instant

/** Unknown roles are displayable, never a source of local authority. */
enum class MessageRole { USER, ASSISTANT, SYSTEM, UNKNOWN }
enum class AuthorType { HUMAN, AGENT, SYSTEM, UNKNOWN }

data class Message(
    val id: String,
    val conversationId: String,
    val revision: Long,
    val discarded: Boolean,
    val role: MessageRole = MessageRole.UNKNOWN,
    val content: String? = null,
    val completed: Boolean = false,
    val clientMessageId: String? = null,
    val createdAt: Instant? = null,
    val updatedAt: Instant? = null,
    val authorType: AuthorType = AuthorType.UNKNOWN,
    val authorId: String? = null,
) {
    /** Presentation hint only; confirmed membership and server authorization still required. */
    fun isOwnModifiableHumanMessage(viewerId: String): Boolean =
        !discarded && role == MessageRole.USER && authorType == AuthorType.HUMAN && authorId == viewerId
}

data class ChangesPage(
    val changes: List<Message>,
    val nextSince: Long,
    val hasMore: Boolean,
    val latestRevision: Long,
)

/** Narrow v1 boundary: additive keys ignored; required types and bigint ranges checked. */
object Wire {
    private val json = Json

    fun changes(payload: String): ChangesPage {
        val root = json.parseToJsonElement(payload).jsonObject
        return ChangesPage(
            root.getValue("changes").jsonArray.map { message(it.jsonObject) },
            root.revision("next_since"),
            root.boolean("has_more"),
            root.revision("latest_revision"),
        )
    }

    fun acceptance(payload: String): Message =
        message(json.parseToJsonElement(payload).jsonObject.getValue("message").jsonObject)

    fun history(payload: String): List<Message> =
        json.parseToJsonElement(payload).jsonObject.getValue("messages").jsonArray.map { message(it.jsonObject) }

    private fun message(root: JsonObject): Message {
        val id = root.string("id")
        val conversationId = root.string("conversation_id")
        val revision = root.revision("revision")
        require(revision > 0)
        // A marker can never retain a body, even if a future server adds one.
        if (root.boolean("discarded")) return Message(id, conversationId, revision, true)
        val role = when (root.string("role")) {
            "user" -> MessageRole.USER
            "assistant" -> MessageRole.ASSISTANT
            "system" -> MessageRole.SYSTEM
            else -> MessageRole.UNKNOWN
        }
        val author = root.getValue("author").jsonObject
        return Message(
            id, conversationId, revision, false, role,
            root.string("content"), root.boolean("completed"),
            root["client_message_id"]?.takeUnless { it is JsonNull }?.let {
                require(it is JsonPrimitive && it.isString)
                it.content
            },
            Instant.parse(root.string("created_at")),
            Instant.parse(root.string("updated_at")),
            when (author.string("type")) {
                "human" -> AuthorType.HUMAN
                "agent" -> AuthorType.AGENT
                "system" -> AuthorType.SYSTEM
                else -> AuthorType.UNKNOWN
            },
            author["id"]?.takeUnless { it is JsonNull }?.let {
                require(it is JsonPrimitive && it.isString)
                it.content
            },
        )
    }

    private fun JsonObject.string(key: String): String {
        val value = getValue(key).jsonPrimitive
        require(value.isString) { "$key must be a string" }
        return value.content
    }

    private fun JsonObject.boolean(key: String): Boolean {
        val value = getValue(key).jsonPrimitive
        require(!value.isString) { "$key must be a boolean" }
        return requireNotNull(value.booleanOrNull) { "$key must be a boolean" }
    }

    private fun JsonObject.revision(key: String): Long {
        val value = getValue(key).jsonPrimitive
        require(!value.isString) { "$key must be an integer" }
        return requireNotNull(value.longOrNull).also { require(it >= 0) }
    }

    internal fun submission(id: String, content: String, attachments: List<String>): String =
        buildJsonObject {
            put("client_message_id", id)
            put("content", content)
            // Empty arrays are invalid on v1; absence represents no attachments.
            if (attachments.isNotEmpty()) putJsonArray("attachment_ids") {
                attachments.forEach { add(it) }
            }
        }.toString()
}
