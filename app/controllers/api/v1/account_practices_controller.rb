module Api
  module V1
    # The account's practices (GET/POST/PATCH/DELETE /api/v1/account_practices),
    # as on the web's Practices tab. A person acts in an account where they are
    # a confirmed member. A resident acts only in its home account: naming any
    # other account is 404, so a guest reads its host's practices in its wake
    # but cannot change them.
    class AccountPracticesController < BaseController

      include ApiHomeAccountOnly
      include AccountPracticeActions

      before_action :set_practices_account
      before_action :set_practice, only: %i[update destroy]

      def index
        response.headers["Cache-Control"] = "no-store"
        render json: { account_id: @account.to_param, **practices_payload(@account) }
      end

      def create
        return render_unprocessable("Provide text") if practice_text_param.blank?

        practice = AccountPractice.add!(account: @account, text: practice_text_param, position: practice_position_param,
          by: actor, request: practice_request_context)
        render json: { practice: practice.as_json }, status: :created
      rescue ActiveRecord::RecordInvalid => error
        render_invalid(error.record)
      end

      def update
        if practice_text_param.nil? && practice_position_param.nil?
          return render_unprocessable("Provide text or position")
        end

        @practice.revise!(text: practice_text_param, position: practice_position_param, by: actor,
          request: practice_request_context)
        render json: { practice: @practice.as_json }
      rescue ActiveRecord::RecordInvalid => error
        render_invalid(error.record)
      end

      def destroy
        @practice.remove!(by: actor, request: practice_request_context)
        render json: { removed: @practice.as_json }
      end

      private

      def set_practices_account
        @account = current_api_agent ? current_api_agent.account : human_account!
      end

      def set_practice
        @practice = @account.account_practices.find(params[:id])
      end

      def actor
        current_api_agent || current_api_user
      end

      def render_unprocessable(message)
        render json: { error: message }, status: :unprocessable_entity
      end

      def render_invalid(record)
        render json: { error: record.errors.full_messages.to_sentence.presence || "Invalid", errors: record.errors.to_hash },
          status: :unprocessable_entity
      end

    end
  end
end
