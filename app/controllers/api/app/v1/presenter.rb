module Api
  module App
    module V1
      # The one JSON shape of the native-app API (issue #94 B, ADR 0003). Built
      # by hand rather than from the models' json_attributes, so a web-only
      # attribute can never leak into the phone contract by being added there.
      module Presenter

        module_function

        def account(account, membership)
          {
            id: account.to_param,
            name: account.name,
            type: account.account_type,
            role: membership.role
          }
        end

        def conversation(chat)
          {
            id: chat.to_param,
            account_id: chat.account.to_param,
            title: chat.title_or_default,
            archived: chat.archived?,
            respondable: chat.respondable?,
            manual_responses: chat.manual_responses,
            participants: chat.agents.map { |agent| { type: "agent", id: agent.to_param, name: agent.name } },
            latest_revision: chat.message_revision,
            updated_at: chat.updated_at.iso8601(6)
          }
        end

        # A discarded message is a marker: identity and revision only. Its
        # retained body and attachments stay server-side (ADR 0001).
        def message(message, viewer:)
          return discarded_marker(message) if message.discarded?

          {
            id: message.to_param,
            conversation_id: message.chat.to_param,
            revision: message.revision,
            discarded: false,
            role: message.role,
            author: author(message),
            content: message.content,
            completed: message.completed?,
            attachments: attachments(message),
            client_message_id: (message.client_message_id if message.user_id.present? && message.user_id == viewer.id),
            created_at: message.created_at.iso8601(6),
            updated_at: message.updated_at.iso8601(6)
          }
        end

        def discarded_marker(message)
          {
            id: message.to_param,
            conversation_id: message.chat.to_param,
            revision: message.revision,
            discarded: true
          }
        end

        def author(message)
          id = (message.agent || message.user)&.to_param
          { type: message.author_type, id: id, name: message.author_name }
        end

        # Download URLs arrive with the attachment endpoint (step 4c).
        def attachments(message)
          return [] unless message.attachments.attached?

          message.attachments.map do |file|
            { id: file.id, filename: file.filename.to_s, content_type: file.content_type, byte_size: file.byte_size }
          end
        end

      end
    end
  end
end
