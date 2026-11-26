module Api
  module V1
    module Visiting
      # The visited house's half of visitors (JdWxAj). A visit token is not an
      # API key: it authenticates only here, and every request re-checks the
      # admission, the account and (per conversation) the seat.
      class BaseController < ActionController::API

        rescue_from ActiveRecord::RecordNotFound, Hashids::InputError do
          render json: { error: "Not found" }, status: :not_found
        end

        private

        def authenticate_visit!
          token = request.authorization.to_s[/\ABearer\s+(\S+)\z/, 1]
          @admission = VisitorAdmission.authenticate(token)
          unless @admission && @admission.account.disabled_at.nil?
            return render json: { error: "This visit is not current" }, status: :unauthorized
          end

          @admission.update_column(:last_seen_at, Time.current) if @admission.last_seen_at.nil? || @admission.last_seen_at < 1.minute.ago
        end

        def current_admission = @admission
        def visiting_agent = @admission.agent

        # A conversation the visitor is seated in now; anything else is 404.
        def seated_chat!(id = params[:conversation_id] || params[:id])
          chat = current_admission.account.chats.find(id)
          raise ActiveRecord::RecordNotFound unless current_admission.seated_in?(chat) && chat.respondable?

          chat
        end

        def wake_for(chat)
          return nil if params[:wake_id].blank?

          current_admission.visitor_wakes.find_by!(id: VisitorWake.decode_id(params[:wake_id]), chat_id: chat.id)
        end

      end
    end
  end
end
