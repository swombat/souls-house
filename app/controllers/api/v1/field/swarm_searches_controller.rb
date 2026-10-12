module Api
  module V1
    module Field
      # Field swarm search (FieldSwarm): one cheap reader per tagged item,
      # asked one question. Expensive; for deeper research, not everyday
      # lookups (use GET /api/v1/field/search for those). Off unless a site
      # admin has turned it on for the account.
      #
      #   POST /api/v1/field/swarm_search
      #   { "tag": ["granttree"], "grep": "(?i)valuation|offer", "question": "What did Bob say the business was worth?" }
      class SwarmSearchesController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly
        include FieldTagsJson

        require_api_feature_enabled :agents, unless: -> { current_api_agent }

        DISABLED = "Field swarm search isn't enabled for this account. It is a test feature a site admin " \
          "turns on per account (Site Admin → Accounts); ask the people who run souls.house."

        def create
          response.headers["Cache-Control"] = "no-store"
          account = current_api_agent ? current_api_account : human_request_account!
          return render(json: { error: DISABLED }, status: :forbidden) unless account.field_swarm_enabled?
          return unless (tags = tag_params)

          render json: FieldSwarm.new(
            account: account, question: text_param(:question), tags: tags, grep: text_param(:grep),
            kinds: params[:kind].presence && Array(params[:kind]),
            agent: current_api_agent, user: (current_api_user unless current_api_agent)
          ).call
        rescue FieldSwarm::Invalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue FieldSwarm::Disabled
          render json: { error: DISABLED }, status: :forbidden
        rescue FieldSwarm::LimitReached => e
          render json: { error: e.message }, status: :too_many_requests
        end

        private

        def text_param(key)
          value = params[key]
          raise FieldSwarm::Invalid, "#{key} must be text" unless value.nil? || value.is_a?(String)

          value
        end

      end
    end
  end
end
