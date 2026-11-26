module Api
  module V1
    # A resident's own commitments (Commitment, #699 B). Resident keys only,
    # and only the key's own rows. People see and adjust them on the
    # resident's page; there is no API for a person to create one.
    class CommitmentsController < BaseController

      before_action :require_resident!
      before_action :set_commitment, only: %i[show update destroy]

      PAGE_SIZE = 100
      ZONED_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})\z/

      class InvalidDueAt < StandardError; end

      def index
        scope = current_api_agent.commitments.includes(:source_chat, :room, :activation_chat).recent_first
        scope = scope.scheduled if params[:status].to_s == "scheduled"
        render json: { commitments: scope.limit(PAGE_SIZE).map(&:as_json) }
      end

      def show
        render json: { commitment: @commitment.as_json }
      end

      def create
        chat = actionable_chats.find(params.require(:conversation_id))
        return render json: { error: "You are not in that conversation" }, status: :forbidden unless chat.agents.exists?(current_api_agent.id)

        current_api_agent.require_conversation_runtime!
        attributes = {
          agent: current_api_agent, source_chat: chat, text: params[:text], summary: params[:summary],
          due_at: parse_due_at(params[:due_at]), destination: params[:destination].presence || "same_conversation"
        }.merge(parse_recurrence)
        if params[:source_message_id].present?
          attributes[:source_message] = chat.messages.find(params[:source_message_id])
        end
        if attributes[:destination] == "new_conversation"
          attributes[:room] = room_selector_given?(params) ? resolve_room_selector(chat.account, params) : chat.account.resident_room
        end

        commitment = Commitment.new(attributes)
        if save_commitment(commitment)
          commitment.announce!
          render json: { commitment: commitment.as_json, receipt: commitment.receipt }, status: :created
        else
          render json: { errors: commitment.errors.full_messages }, status: :unprocessable_entity
        end
      rescue RoomSelectorError, InvalidDueAt, InvalidRecurrence => error
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end

      # Reschedule: only due_at changes. A different promise is a new
      # commitment.
      def update
        result = @commitment.reschedule!(due_at: parse_due_at(params[:due_at]))
        case result.status
        when :rescheduled
          render json: { commitment: @commitment.as_json, receipt: @commitment.receipt }
        when :not_scheduled
          render json: { errors: [ "Only a scheduled commitment can be rescheduled (this one is #{@commitment.status})" ] }, status: :conflict
        else
          render json: { errors: @commitment.errors.full_messages }, status: :unprocessable_entity
        end
      rescue InvalidDueAt => error
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end

      def destroy
        result = @commitment.cancel!(by: current_api_agent)
        if result.status.in?(%i[cancelled series_ended])
          render json: { commitment: @commitment.reload.as_json, series_ended: @commitment.recurring? }
        else
          render json: { errors: [ "Only a commitment not yet delivered can be cancelled (this one is #{@commitment.status}#{@commitment.wake_state ? ", wake #{@commitment.wake_state}" : ""})" ] }, status: :conflict
        end
      end

      private

      def require_resident!
        response.headers["Cache-Control"] = "no-store"
        return if current_api_agent

        render json: { error: "Commitments are only available to resident API keys" }, status: :forbidden
      end

      def set_commitment
        @commitment = current_api_agent.commitments.find(params[:id])
      end

      def parse_due_at(value)
        message = "due_at must be ISO 8601 with a zone, e.g. 2026-11-03T03:00:00+01:00"
        raise InvalidDueAt, message unless value.is_a?(String) && value.strip.match?(ZONED_TIME)

        Time.iso8601(value.strip).utc
      rescue ArgumentError
        raise InvalidDueAt, message
      end

      class InvalidRecurrence < StandardError; end

      # recur_every_minutes for a fixed interval, or recur_min_minutes with
      # recur_max_minutes for a random pick in that range. Nothing given is a
      # one-shot commitment.
      def parse_recurrence
        every, min, max = params.values_at(:recur_every_minutes, :recur_min_minutes, :recur_max_minutes).map(&:presence)
        return {} if [ every, min, max ].all?(&:nil?)
        if every && (min || max)
          raise InvalidRecurrence, "Give recur_every_minutes, or recur_min_minutes with recur_max_minutes, not both"
        end

        min, max = every, every if every
        raise InvalidRecurrence, "recur_min_minutes and recur_max_minutes go together" unless min && max

        { recur_min_minutes: whole_minutes(min), recur_max_minutes: whole_minutes(max) }
      end

      def whole_minutes(value)
        Integer(value.to_s, 10)
      rescue ArgumentError
        raise InvalidRecurrence, "Recurrence minutes must be whole numbers"
      end

      # The unique index is the last word on duplicates: a race between two
      # saves of the same text is refused like the validation refuses it.
      def save_commitment(commitment)
        commitment.save
      rescue ActiveRecord::RecordNotUnique
        commitment.errors.add(:text, "is the same as a commitment already scheduled; give each commitment its own text")
        false
      end

    end
  end
end
