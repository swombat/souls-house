module Api
  module V1
    # Residents post to a LinkedIn profile whose connection the owner has
    # shared with them (LinkedinPoster). Only connections reachable through
    # the resident's own effective accesses are ever used.
    class LinkedinPostsController < BaseController

      FAILURE_STATUSES = {
        "rate_limited" => :too_many_requests,
        "rejected" => :unprocessable_entity,
        "reconnect_needed" => :conflict,
        "unauthorized" => :conflict,
        "access_removed" => :forbidden,
        "forbidden" => :bad_gateway
      }.freeze

      before_action :require_resident

      def create
        result = LinkedinPoster.new(agent: current_api_agent).post!(
          text: params[:text],
          media: params[:media].presence,
          connection_id: params[:connection],
          idempotency_key: request.headers["Idempotency-Key"]
        )
        render_post(result.post, replayed: result.replayed)
      rescue LinkedinPoster::Refused => e
        render json: { error: e.message, code: e.code }, status: e.http_status
      end

      def show
        post = find_post
        return render json: { error: "Not found" }, status: :not_found unless post

        render json: post.as_post_json
      end

      def update
        post = find_post
        return render json: { error: "Not found" }, status: :not_found unless post

        post.resolve!(resolution: params[:resolution].to_s, post_urn: LinkedinPost.urn_from(params[:post_url].presence || params[:post_urn]), by: current_api_agent)
        render json: post.reload.as_post_json
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # A resident sees the posts it made, on any connection.
      def find_post
        LinkedinPost.where(agent: current_api_agent).find_by_obfuscated_id(params[:id])
      end

      def render_post(post, replayed:)
        body = post.as_post_json.merge(replayed:)
        case post.status
        when "posted", "resolved_posted"
          render json: body, status: replayed ? :ok : :created
        when "resolved_not_posted"
          render json: body.merge(error: "This key's post was resolved as not posted; use a new Idempotency-Key to post again"), status: :conflict
        when "outcome_unknown"
          message = "LinkedIn may or may not have published this post. It will not be retried automatically; check the profile, then resolve it with PATCH /api/v1/linkedin_posts/#{post.to_param}"
          render json: body.merge(error: message), status: replayed ? :conflict : :gateway_timeout
        when "pending"
          # A media post being sent in the background: poll GET
          # /api/v1/linkedin_posts/:id until it is no longer pending.
          render json: body, status: :accepted
        else
          render json: body, status: FAILURE_STATUSES.fetch(post.failure_reason, :bad_gateway)
        end
      end

      def require_resident
        return if current_api_agent

        render json: { error: "Posting to LinkedIn is only available to resident API keys" }, status: :forbidden
      end

    end
  end
end
