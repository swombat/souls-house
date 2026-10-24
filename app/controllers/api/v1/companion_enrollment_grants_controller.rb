module Api
  module V1
    class CompanionEnrollmentGrantsController < BaseController

      before_action :require_human_actor!, only: :create

      def create
        response.headers["Cache-Control"] = "no-store"
        account = human_account!
        unless human_membership!(account).admin?
          return render json: { error: "Only an account owner or admin may enroll a companion" }, status: :forbidden
        end

        agent_id = params[:minting_agent_id]
        unless agent_id.is_a?(String) && CompanionEnrollmentGrant::PUBLIC_ID.match?(agent_id)
          return render json: { error: "minting_agent_id must be a public resident ID" }, status: :unprocessable_entity
        end
        agent = account.agents.find(agent_id)
        raise ActiveRecord::RecordNotFound unless agent.to_param == agent_id

        unless params[:name].is_a?(String) && params[:name].bytesize.between?(1, 100) &&
            !params[:name].match?(/[[:cntrl:]]/) && params[:device_request_id].is_a?(String)
          return render json: { error: "Invalid name or device_request_id" }, status: :unprocessable_entity
        end

        expiration = params[:expires_at]
        unless expiration.is_a?(String) && expiration.bytesize <= 64
          return render json: { error: "expires_at must be an ISO8601 timestamp" }, status: :unprocessable_entity
        end
        policy = params[:policy]
        grant = CompanionEnrollmentGrant.new(
          account: account, minting_agent: agent, created_by_user: current_api_user,
          name: params[:name], device_request_id: params[:device_request_id],
          policy: policy.is_a?(ActionController::Parameters) ? policy.to_unsafe_h : policy,
          expires_at: Time.iso8601(expiration)
        )
        grant.save!
        audit_human_action("companion.enrollment_grant.created", grant, account: account,
          minting_agent_id: agent.to_param, device_request_id: grant.device_request_id)
        render json: { id: grant.to_param, expires_at: grant.expires_at.iso8601(3),
          authority_warnings: grant.authority_warnings }, status: :created
      rescue ArgumentError
        render json: { error: "Invalid enrollment grant" }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      def token
        response.headers["Cache-Control"] = "no-store"
        unless current_api_agent && current_api_agent.account_id == current_api_account.id &&
            !current_api_account.disabled?
          return render json: { error: "A home resident credential is required" }, status: :forbidden
        end
        id = params[:id]
        raise ActiveRecord::RecordNotFound unless id.is_a?(String) && CompanionEnrollmentGrant::PUBLIC_ID.match?(id)

        grant = CompanionEnrollmentGrant.where(account_id: current_api_account.id, minting_agent_id: current_api_agent.id).find(id)
        value = grant.issue_token!(current_api_agent)
        return render json: { error: "Enrollment grant unavailable" }, status: :conflict unless value

        render json: { enrollment_token: value, device_request_id: grant.device_request_id,
          expires_at: grant.expires_at.iso8601(3) }, status: :created
      end

    end
  end
end
