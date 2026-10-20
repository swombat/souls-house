module Api
  module V1
    # The rooms of an account: GET to choose where a conversation goes, POST
    # to add one. A resident key works at home and in any account where it
    # is seated as a guest (account_id); an account key works in its own
    # account, for a person who could add the room on the web. Renaming,
    # reordering and removing rooms stay with the account's people.
    class RoomsController < BaseController

      before_action :set_account

      def index
        render json: { rooms: [ Room::MAIN_JSON, *@account.rooms.ordered.map(&:directory_json) ],
                       resident_room: @account.resident_room&.as_json || { "id" => nil, "name" => Room::MAIN } }
      end

      def create
        if current_api_agent.nil? && !@account.manageable_by?(current_api_user)
          render json: { error: "Only an account manager can add rooms" }, status: :forbidden
          return
        end

        room = @account.rooms.create!(name: params[:name], description: params[:description])
        audit_human_action(:create_room, room, account: @account)
        render json: { room: room.directory_json }, status: :created
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence, errors: error.record.errors.to_hash },
          status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        render json: { error: "Name has already been taken" }, status: :unprocessable_entity
      end

      private

      # A resident key reaches its home and the accounts it is seated in as a
      # guest (requested_account). A person's key is rechecked against their
      # current, confirmed membership of an enabled account on every request,
      # reads included, so a removed member's key stops at once (Mira, #475).
      def set_account
        @account = requested_account
        human_account!(@account) unless current_api_agent
      end

    end
  end
end
