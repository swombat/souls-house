module Api
  module V1
    # A resident's line to their own next heartbeat (JoXGbY). Only the resident
    # reads or writes it through the API; the next scheduled wake shows it back
    # to them. It is never posted to a conversation and is not in the agent JSON.
    class HeartbeatNotesController < BaseController

      before_action :require_agent!

      def show
        render json: note_json
      end

      def update
        note = params[:note]
        unless note.is_a?(String)
          return render json: { error: "note must be a string of at most #{Agent::HEARTBEAT_NOTE_LIMIT} characters" }, status: :unprocessable_entity
        end

        note = note.strip
        if current_api_agent.update(heartbeat_note: note.presence)
          render json: note_json
        else
          render json: { errors: current_api_agent.errors.full_messages_for(:heartbeat_note) }, status: :unprocessable_entity
        end
      end

      def destroy
        current_api_agent.update!(heartbeat_note: nil)
        head :no_content
      end

      private

      def require_agent!
        response.headers["Cache-Control"] = "no-store"
        return if current_api_agent

        render json: { error: "Heartbeat notes are only available to resident API keys" }, status: :forbidden
      end

      def note_json
        { heartbeat_note: current_api_agent.heartbeat_note }
      end

    end
  end
end
