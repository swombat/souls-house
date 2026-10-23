module Api
  module V1
    # The rooms of an account, with everything Account settings → Rooms does
    # on the web: list, add, rename and describe, reorder, remove, rename and
    # describe Main, the default room for resident-started conversations, and
    # the model a resident starts on in a room.
    #
    # A resident key works at home and in any account where it is seated as a
    # guest (account_id); residents have the same reach over rooms as the
    # account's people (Daniel, PevZqe). An account key works in its own
    # account, for a person who could do the same on the web: reads for any
    # member, changes for an account manager.
    class RoomsController < BaseController

      before_action :set_account
      before_action :require_room_manager!, except: :index

      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { error: error.record.errors.full_messages.to_sentence, errors: error.record.errors.to_hash },
          status: :unprocessable_entity
      end

      rescue_from ActiveRecord::RecordNotUnique do
        render json: { error: "Name has already been taken" }, status: :unprocessable_entity
      end

      def index
        render json: directory
      end

      def create
        room = @account.rooms.create!(name: params[:name], description: params[:description])
        audit_room_action(:create_room, room)
        render json: { room: room.directory_json }, status: :created
      end

      # name and/or description; or direction "up"/"down" to move the room one
      # place, as the web's arrows do.
      def update
        room = Room.resolve_for(@account, params[:id])
        if params.key?(:direction)
          unless params[:direction].in?(%w[up down])
            render json: { error: "direction must be \"up\" or \"down\"" }, status: :unprocessable_entity
            return
          end

          room.move!(params[:direction] == "up" ? -1 : 1)
          audit_room_action(:move_room, room, direction: params[:direction])
        else
          room.update!(params.slice(:name, :description).permit(:name, :description).to_h)
          audit_room_action(:update_room, room, **AuditLog.data_with_changes(room).symbolize_keys)
        end
        render json: directory.merge(room: room.reload.directory_json)
      end

      # Its conversations move to Main, as on the web.
      def destroy
        room = Room.resolve_for(@account, params[:id])
        moved = room.chats.count
        room.destroy!
        audit_room_action(:destroy_room, room, moved_conversations: moved)
        render json: directory.merge(removed: room.directory_json, moved_conversations: moved,
          moved_to: @account.main_room_label)
      end

      # Main has no row: its name and description are account settings.
      def main
        @account.update!(params.slice(:name, :description).permit(:name, :description).to_h.transform_keys { |key| "main_room_#{key}" })
        audit_room_action(:update_main_room, @account, **AuditLog.data_with_changes(@account).symbolize_keys)
        ActionCable.server.broadcast("RoomNavigation:#{@account.to_param}", { action: "refresh" })
        render json: directory.merge(room: @account.main_room_json)
      end

      # Where conversations residents start land when they name no room.
      # room_id null (or "main") is Main.
      def resident_room
        unless params.key?(:room_id)
          render json: { error: "room_id is required (null for Main)" }, status: :unprocessable_entity
          return
        end

        room_id = params[:room_id].presence
        @account.update!(resident_room: room_id.nil? || room_id == "main" ? nil : Room.resolve_for(@account, room_id))
        audit_room_action(:update_resident_room, @account, **AuditLog.data_with_changes(@account).symbolize_keys)
        render json: directory
      end

      # The model a resident starts on in new conversations in a room
      # (room_id "main" or null for Main). model_id "default", empty, or the
      # resident's own model clears the room's choice.
      def model_default
        room_id = params[:room_id].presence
        room = room_id.nil? || room_id == "main" ? nil : Room.resolve_for(@account, room_id)
        agent = @account.agents.find(Agent.decode_id(params[:agent_id].to_s) || 0)
        record = RoomModelDefault.set!(account: @account, room: room, agent: agent, model_id: params[:model_id])
        audit_room_action(:update_room_model_default, room || @account,
          room: room&.name || @account.main_room_label, agent: agent.name, model_id: record&.model_id)
        render json: { room_model_default: record&.as_json,
                       room_model_defaults: @account.room_model_defaults.includes(:room, :agent).map(&:as_json) }
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

      # Residents with a seat here may manage its rooms; a person's key needs
      # what the web needs, an account manager.
      def require_room_manager!
        return if current_api_agent || @account.manageable_by?(current_api_user)

        render json: { error: "Only an account manager can change rooms" }, status: :forbidden
      end

      def directory
        { rooms: [ @account.main_room_json, *@account.rooms.ordered.map(&:directory_json) ],
          resident_room: @account.resident_room&.as_json || { "id" => nil, "name" => @account.main_room_label } }
      end

      # The key's person, as everywhere in the API's audit trail, with the
      # resident named when a resident key acted.
      def audit_room_action(action, auditable, **data)
        data[:agent_id] = current_api_agent.to_param if current_api_agent
        data[:agent_name] = current_api_agent.name if current_api_agent
        audit_human_action(action, auditable, account: @account, **data)
      end

    end
  end
end
