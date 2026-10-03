module Api
  module V1
    class RhythmsController < BaseController

      before_action :set_rhythm
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.to_hash(true) }, status: :unprocessable_entity
      end

      def show
        render_state
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

      def set_rhythm
        raise ActiveRecord::RecordNotFound unless current_api_agent

        # Former participants may release their own surviving hold, but cannot
        # inspect rhythms merely by knowing an opaque identifier.
        selected = Rhythm.joins(:rhythm_agents).where(rhythm_agents: { agent_id: current_api_agent.id }).select(:id)
        held = RhythmHold.where(agent: current_api_agent, released_at: nil).select(:rhythm_id)
        reachable = Account.where(id: current_api_account.id)
          .or(Account.where(id: current_api_agent.guest_memberships.select(:account_id)))
        @rhythm = Rhythm.where(account: reachable).where(id: selected)
          .or(Rhythm.where(account: reachable).where(id: held)).find(params[:id])
      end

      def render_state(result = nil)
        response.headers["Cache-Control"] = "no-store"
        render json: {
          rhythm: RhythmPresentation.new(@rhythm, agent: current_api_agent).as_json,
          result: result&.status, reason: result&.reason
        }, status: result&.status == :forbidden ? :forbidden : :ok
      end

    end
  end
end
