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
        #
        # Native replies arrive complete (ADR 0004). Streaming chunks don't take
        # a revision, so a row mid-stream is shown with its body withheld and
        # completed: false; stop_streaming saves, bumps the revision, and the
        # finished reply reaches the client through changes.
        def message(message, viewer:)
          return discarded_marker(message) if message.discarded?

          streaming = message.streaming?

          {
            id: message.to_param,
            conversation_id: message.chat.to_param,
            revision: message.revision,
            discarded: false,
            role: message.role,
            author: author(message),
            content: (streaming ? "" : message.content),
            completed: !streaming && message.completed?,
            attachments: (streaming ? [] : attachments(message)),
            client_message_id: (message.client_message_id if message.user_id.present? && message.user_id == viewer.id),
            created_at: message.created_at.iso8601(6),
            updated_at: message.updated_at.iso8601(6)
          }
        end

        # A resident's run in a conversation, status only. The web panel's
        # working narration and event log aren't part of the phone contract in
        # v1; replies arrive as messages through changes.
        def activity(interaction)
          # status and active as the web panel shows them, live runs included.
          web = interaction.as_chat_activity_json
          {
            id: interaction.to_param,
            conversation_id: interaction.chat.to_param,
            agent: { type: "agent", id: interaction.agent.to_param, name: interaction.agent.name },
            trigger_kind: interaction.trigger_kind,
            status: web[:status],
            active: web[:active],
            created_at: interaction.created_at.iso8601(6),
            started_at: interaction.started_at&.iso8601(6),
            finished_at: interaction.finished_at&.iso8601(6)
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

        # download_path answers with a redirect to a short-lived storage URL
        # (attachments#show); fetch it with the bearer, follow without it.
        # Files are in submission order: an app send records each file's
        # position on its blob (PostFromHuman#claim_uploads); others go by
        # attachment id, after any positioned file.
        def attachments(message)
          return [] unless message.attachments.attached?

          routes = Rails.application.routes.url_helpers
          ordered = message.attachments.sort_by { |file| [ file.blob.metadata["position"] || Float::INFINITY, file.id ] }
          ordered.map do |file|
            {
              id: file.id,
              filename: file.filename.to_s,
              content_type: file.content_type,
              byte_size: file.byte_size,
              download_path: routes.api_app_v1_conversation_message_attachment_path(message.chat.to_param, message.to_param, file.id)
            }
          end
        end

      end
    end
  end
end
