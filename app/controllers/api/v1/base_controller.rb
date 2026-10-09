module Api
  module V1
    class BaseController < ActionController::API

      include ApiAuthentication
      include ApiHumanActor
      # After authentication, which ApiAuthentication's before_action does.
      # PaperTrail 17 no longer adds this callback itself.
      before_action :set_paper_trail_whodunnit

      rescue_from Agent::RuntimeAvailability::Unavailable do |error|
        render json: { error: error.message, code: error.code }, status: :conflict
      end

      # Hashids::InputError: a malformed obfuscated id is a missing record, not a 500
      # (same rule as Api::App::V1::BaseController).
      rescue_from ActiveRecord::RecordNotFound, Hashids::InputError do
        render json: { error: "Not found" }, status: :not_found
      end

      private

      # Who made a versioned change: the resident when a resident key acts,
      # otherwise the person who owns the key. A Proc, so it is read when the
      # version is written.
      def user_for_paper_trail
        -> { ItemVersion.whodunnit_for(current_api_agent || current_api_user) }
      end

      # The editor to record on items with last_edited_by. Same rule as above.
      def current_api_editor
        current_api_agent || current_api_user
      end

      # The account a request acts in. Defaults to the key's home account. A
      # resident key may name an account where it is currently a guest; any
      # other account_id is 404, so a departed guest loses the door at once.
      def requested_account
        return current_api_account if params[:account_id].blank?

        reachable = Account.where(id: current_api_account.id)
        reachable = reachable.or(Account.where(id: current_api_agent.guest_memberships.select(:account_id))) if current_api_agent
        reachable.find(params[:account_id])
      end

      # Rooms a key may act in: its account's rooms and, for a resident key,
      # every room where that resident holds a seat, at home or as a guest.
      def actionable_chats
        return human_chats unless current_api_agent

        Chat.where(account_id: current_api_account.id)
          .or(Chat.where(id: current_api_agent.chat_agents.select(:chat_id)))
      end

    end
  end
end
