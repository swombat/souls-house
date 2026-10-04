module Api
  module V1
    class RhythmsController < BaseController

      PAGE_SIZE = 100
      FORBIDDEN_FIELDS = %w[resident_ids agent_ids agents creator creator_id creator_agent creator_agent_id user_id].freeze

      before_action :require_resident
      before_action :set_rhythm, except: %i[index create]
      before_action :require_rhythm_object, only: %i[create update]
      before_action :reject_attribution_or_selection, only: %i[create update]
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.to_hash(true) }, status: :unprocessable_entity
      end

      def index
        scope = Rhythm.where(account: requested_account).order(id: :desc)
        unless params[:cursor].nil? || (params[:cursor].is_a?(String) && params[:cursor].match?(/\A[a-zA-Z0-9]{0,100}\z/))
          return render json: { error: "Invalid cursor" }, status: :unprocessable_entity
        end
        if params[:cursor].present?
          cursor = scope.find(params[:cursor])
          scope = scope.where("rhythms.id < ?", cursor.id)
        end
        rhythms = scope.includes(:creator, :creator_agent, :agents, :open_holds).limit(PAGE_SIZE + 1).to_a
        response.headers["Cache-Control"] = "no-store"
        render json: {
          rhythms: rhythms.first(PAGE_SIZE).map { |rhythm| RhythmPresentation.new(rhythm, agent: current_api_agent).as_json },
          next_cursor: rhythms.length > PAGE_SIZE ? rhythms[PAGE_SIZE - 1].to_param : nil
        }
      end

      def show
        render_state
      end

      def create
        current_api_agent.require_conversation_runtime!
        @rhythm = Rhythm.create!(rhythm_params.merge(
          account: requested_account, creator_agent: current_api_agent, agents: [ current_api_agent ]
        ))
        render_state(status: :created)
      end

      def update
        @rhythm.with_lock do
          return render_state(Rhythm::Result.new(status: :forbidden)) unless @rhythm.manageable_by_agent?(current_api_agent)

          @rhythm.update!(rhythm_params)
        end
        render_state
      end

      def destroy
        @rhythm.with_lock do
          return render_state(Rhythm::Result.new(status: :forbidden)) unless @rhythm.manageable_by_agent?(current_api_agent)

          @rhythm.destroy!
        end
        head :no_content
      end

      def join
        render_state(@rhythm.join!(agent: current_api_agent))
      end

      def leave
        render_state(@rhythm.leave!(agent: current_api_agent))
      end

      def pause
        result = @rhythm.pause!(holder: current_api_agent, reason: params[:reason].to_s.presence || "Paused by #{current_api_agent.name}")
        render_state(result)
      end

      def resume
        result = @rhythm.resume!(holder: current_api_agent)
        render_state(result)
      end

      private

      def require_resident
        raise ActiveRecord::RecordNotFound unless current_api_agent
      end

      def set_rhythm
        # Discovery grants no occurrence/chat access. A departed guest loses
        # this account door even when it still owns a surviving hold.
        reachable = Account.where(id: current_api_account.id)
          .or(Account.where(id: current_api_agent.guest_memberships.select(:account_id)))
        reachable = reachable.where(id: requested_account.id) if params[:account_id].present?
        @rhythm = Rhythm.where(account: reachable).find(params[:id])
      end

      def reject_attribution_or_selection
        fields = params.keys & FORBIDDEN_FIELDS
        fields |= params[:rhythm].keys & FORBIDDEN_FIELDS if params[:rhythm].is_a?(ActionController::Parameters)
        return if fields.empty?

        render json: { errors: { rhythm: [ "Creator and resident selection cannot be supplied; use self join/leave" ] } },
          status: :unprocessable_entity
      end

      def require_rhythm_object
        return if params[:rhythm].is_a?(ActionController::Parameters)

        render json: { errors: { rhythm: [ "must be an object" ] } }, status: :unprocessable_entity
      end

      def rhythm_params
        params[:rhythm].permit(:title, :opening, :append_date, :cadence, :time_of_day,
          :weekday, :month_day, :month, :timezone).to_h.symbolize_keys
      end

      def render_state(result = nil, status: :ok)
        response.headers["Cache-Control"] = "no-store"
        render json: {
          rhythm: RhythmPresentation.new(@rhythm, agent: current_api_agent).as_json,
          result: result&.status, reason: result&.reason
        }, status: case result&.status
                   when :forbidden then :forbidden
                   when :unavailable then :conflict
                   else status
                   end
      end

    end
  end
end
