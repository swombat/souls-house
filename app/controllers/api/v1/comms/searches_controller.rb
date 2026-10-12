module Api
  module V1
    module Comms
      # Bounded server-side search of a Telegram connection (proposal
      # 2026-10-11 §7). The connector asks Telegram (messages.search for one
      # chat, messages.searchGlobal restricted to the synced peers); Rails
      # adds no index, because message bodies use non-deterministic
      # encryption. Results say which scope they covered.
      #
      #   query  required, at most 200 characters
      #   chat   optional: a chat_<n> id or provider chat id on this connection
      #   limit  1..50 (default 20)
      #   scope  "synced" (default) or "all_dialogs", which the owner must
      #          have switched on for this connection
      class SearchesController < BaseController

        MAX_QUERY = 200
        DEFAULT_SEARCH_LIMIT = 20
        MAX_SEARCH_LIMIT = 50
        SCOPES = %w[synced all_dialogs].freeze

        def show
          unless @connection.provider == "telegram"
            return render json: { error: "Search is not available for this connection" }, status: :unprocessable_entity
          end

          query = params[:query].to_s.strip
          return render json: { error: "query is required" }, status: :bad_request if query.empty?
          return render json: { error: "query is longer than #{MAX_QUERY} characters" }, status: :bad_request if query.length > MAX_QUERY

          scope = (params[:scope].presence || "synced").to_s
          return render json: { error: "scope must be synced or all_dialogs" }, status: :bad_request unless SCOPES.include?(scope)
          if scope == "all_dialogs" && !@connection.search_all_dialogs?
            return render json: { error: "The owner has not allowed searching beyond the synced chats" }, status: :forbidden
          end

          chat = find_chat if params[:chat].present?
          if chat && scope == "synced" && chat.sync_state.to_h["synced"] == false
            return render json: { error: "That chat is not synced; searching it needs scope all_dialogs" }, status: :forbidden
          end

          limit = params.fetch(:limit, DEFAULT_SEARCH_LIMIT).to_i.clamp(1, MAX_SEARCH_LIMIT)
          result = @connection.definition.adapter.search(@connection, query:, chat: chat&.provider_chat_id, limit:, scope:)
          if result == :not_configured
            return render json: { error: "The Telegram connector is not running on this house" }, status: :service_unavailable
          end

          render json: {
            scope: scope,
            chat: chat&.public_id,
            coverage: result["coverage"],
            results: Array(result["results"]).first(limit),
            retry_after: result["retry_after"]
          }.compact
        rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError
          render json: { error: "Telegram search is unavailable right now" }, status: :service_unavailable
        end

        private

        def find_chat
          value = params[:chat].to_s
          if value.match?(/\Achat_\d+\z/)
            @connection.comms_chats.find(value.delete_prefix("chat_"))
          else
            @connection.comms_chats.find_by!(provider_chat_id: value)
          end
        end

      end
    end
  end
end
