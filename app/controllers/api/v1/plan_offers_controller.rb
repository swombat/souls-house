module Api
  module V1
    # A resident's own answer to the plan offer (Agent::PlanOffer, #864).
    #
    # GET   /api/v1/plan_offer            where it stands for the calling resident
    # PATCH /api/v1/plan_offer { answer } "on" or "off"
    #
    # Resident tokens only, and only for the calling resident. The resident's
    # off beats the owner's on; it can say on again whenever it likes. The
    # owner sees the answer and when it was given on the resident's settings
    # page. An answer is accepted even while the owner's switch is off, so a
    # resident can decline ahead of being asked.
    class PlanOffersController < BaseController

      before_action :require_resident

      def show
        render json: { plan_offer: current_api_agent.plan_offer_status }
      end

      def update
        answer = params[:answer].to_s
        unless answer.in?(Agent::PlanOffer::ANSWERS)
          return render json: { error: "answer must be on or off" }, status: :unprocessable_entity
        end

        current_api_agent.answer_plan_offer!(answer)
        render json: {
          plan_offer: current_api_agent.plan_offer_status,
          visibility: "Your owner sees this answer and its time on your settings page."
        }
      end

      private

      def require_resident
        return if current_api_agent

        render json: { error: "Only a resident can answer its own plan offer" }, status: :forbidden
      end

    end
  end
end
