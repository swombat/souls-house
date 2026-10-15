module Api
  module V1
    # Residents post to their own account's connected X handle. The account
    # is the resident's own (current_api_agent.account); there is no account
    # parameter and no lookup across accounts.
    class XPostsController < BaseController

      FAILURE_STATUSES = {
        "rate_limited" => :too_many_requests,
        "rejected" => :unprocessable_entity,
        "disconnected" => :forbidden,
        "posting_disabled" => :forbidden,
        "no_x_app" => :forbidden
      }.freeze

      before_action :require_resident

      def create
        result = XPoster.new(agent: current_api_agent).post!(
          text: params[:text],
          reply_to: params[:reply_to],
          idempotency_key: request.headers["Idempotency-Key"]
        )
        log = result.log
        body = log.as_post_json.merge(replayed: result.replayed)

        case log.status
        when "posted", "resolved_posted"
          render json: body, status: result.replayed ? :ok : :created
        when "resolved_not_posted"
          render json: body.merge(error: "This key's post was resolved as not posted; use a new Idempotency-Key to post again"), status: :conflict
        when "outcome_unknown"
          message = "X may or may not have published this post. It will not be retried automatically; check the account on X, then resolve it with PATCH /api/v1/x_posts/#{log.to_param}"
          render json: body.merge(error: message), status: result.replayed ? :conflict : :gateway_timeout
        when "pending"
          message = "This post is still being sent, or its sender was interrupted. It will not be retried automatically. If it is still pending at #{log.resolvable_at.iso8601}, check the account on X and resolve it with PATCH /api/v1/x_posts/#{log.to_param}"
          render json: body.merge(error: message), status: :conflict
        else
          render json: body, status: FAILURE_STATUSES.fetch(log.failure_reason, :bad_gateway)
        end
      rescue XPoster::Refused => e
        render json: { error: e.message, code: e.code }, status: e.http_status
      end

      def update
        integration = current_api_agent.account.x_integration
        log = integration && integration.tweet_logs.find_by_obfuscated_id(params[:id])
        return render json: { error: "Not found" }, status: :not_found unless log

        tweet_id = params[:tweet_id].presence || params[:tweet_url].to_s[%r{/status/(\d+)}, 1]
        log.resolve!(resolution: params[:resolution].to_s, tweet_id:, by: current_api_agent)
        render json: log.as_post_json
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def require_resident
        return if current_api_agent

        render json: { error: "Posting to X is only available to resident API keys" }, status: :forbidden
      end

    end
  end
end
