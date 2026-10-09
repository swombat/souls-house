module Api
  module V1
    # Resident settings for a person's credential (an account key or an OAuth
    # app token): the API side of the web resident pages (AgentsController and
    # its retry/service-access controllers). Same authority as the web, which
    # lets any confirmed member of an enabled account manage its home
    # residents. Authority is checked against the resident's own account.
    # Resident keys are refused: a resident does not manage itself or its
    # housemates through these routes.
    #
    # Not here, by design: memory writes, portability, predecessor, sandbox
    # recreation, provider subscriptions, runtime checks, Telegram tests and
    # webhooks, tailnet, hosting diagnostics and the Telegram deep link.
    class ResidentsController < BaseController

      include AgentSettingsParams

      before_action :require_human_actor!
      before_action :require_residents_enabled!
      before_action :set_account, only: [ :catalogue, :create ]
      before_action :set_agent, except: [ :catalogue, :create ]

      rescue_from ActionController::ParameterMissing do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end

      # GET /api/v1/residents/catalogue
      def catalogue
        render json: {
          grouped_models: Agents::ModelCatalogue.grouped,
          default_model_id: Agents::HostedBirth.default_model_id(account: @account, creator: current_api_user),
          birth_refusal: Agents::VmBirthPolicy.current.refusal(kind: :birth),
          reasoning_efforts: Agent::REASONING_EFFORTS,
          colour_options: Agent::VALID_COLOURS,
          icon_options: Agent::VALID_ICONS
        }
      end

      # GET /api/v1/residents/:id
      def show
        render json: settings_json
      end

      # POST /api/v1/residents
      def create
        attrs = birth_params
        open_beginning = ActiveModel::Type::Boolean.new.cast(attrs.delete(:open_beginning))
        @agent = Agents::HostedBirth.new(
          account: @account,
          creator: current_api_user,
          attributes: attrs,
          open_beginning: open_beginning
        ).create!
        audit_human_action("create_agent", @agent, account: @account, **agent_audit_data(attrs))
        render json: { agent: @agent.as_json, provisioning: provisioning_json }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e.record.errors)
      rescue Agents::HostedProvisioning::ConfigurationError => e
        render json: { error: e.message, errors: { base: [ e.message ] } }, status: :unprocessable_entity
      end

      # PATCH /api/v1/residents/:id
      def update
        attrs = agent_params
        @agent.update_settings!(attrs, by: current_api_user)
        audit_human_action("update_agent", @agent, account: @account, **agent_audit_data(attrs))
        render json: settings_json
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e.record.errors)
      end

      # DELETE /api/v1/residents/:id
      # Disables, as the web does. History, identity and memory are kept;
      # PATCH active: true re-enables.
      def destroy
        @agent.update!(active: false)
        audit_human_action("disable_agent", @agent, account: @account)
        render json: { agent: @agent.as_json }
      end

      # GET /api/v1/residents/:id/provisioning
      def provisioning
        render json: { agent_id: @agent.to_param, provisioning: provisioning_json }
      end

      # POST /api/v1/residents/:id/provisioning_retry
      def provisioning_retry
        unless @agent.provisioning_retryable?
          return render json: { error: "This resident is not waiting for provisioning" }, status: :conflict
        end

        @agent.retry_provisioning!
        render json: { agent_id: @agent.to_param, provisioning: provisioning_json }, status: :accepted
      end

      # POST /api/v1/residents/:id/orientation_retry
      def orientation_retry
        unless @agent.orientation_retryable?
          return render json: { error: "The runtime must be healthy before orientation" }, status: :conflict
        end

        @agent.retry_orientation!
        render json: { agent_id: @agent.to_param, provisioning: provisioning_json }, status: :accepted
      end

      # GET /api/v1/residents/:id/memory_overview
      # Counts only, as on the web Memory tab. No memory text.
      def memory_overview
        response.headers["Cache-Control"] = "private, no-store"
        render json: Agents::MemoryOverview.new(@agent).call
      end

      # PATCH /api/v1/residents/:id/service_accesses/:connection_id
      def service_access
        connection = @account.service_connections.find_by_public_id!(params[:connection_id])
        enabled = ActiveModel::Type::Boolean.new.cast(params.require(:enabled))
        if enabled && connection.status != "connected"
          return render json: { error: "Reconnect this service before enabling resident access" }, status: :conflict
        end
        unless connection.resident_access_changeable_by?(current_api_user, enabled: enabled)
          return render json: { error: "You cannot change this resident's access" }, status: :forbidden
        end

        access = @agent.set_service_access!(connection, enabled: enabled)
        audit_human_action(enabled ? :enable_resident_service : :disable_resident_service,
                           connection,
                           account: @account,
                           resident_id: @agent.to_param,
                           provider: connection.provider)
        render json: { service_connection: service_connection_json(connection, access) }
      end

      # PATCH /api/v1/residents/:id/service_accesses/:connection_id/send_grant
      # Lets the resident send through a comms connection as its owner, or
      # stops it. Only the owner can grant; whoever manages the connection
      # can withdraw.
      def service_send_grant
        connection = @account.service_connections.find_by_public_id!(params[:connection_id])
        can_send = ActiveModel::Type::Boolean.new.cast(params.require(:can_send))
        unless connection.send_grant_changeable_by?(current_api_user, can_send: can_send)
          return render json: { error: can_send ? "Only the connection's owner can let a resident send" : "You cannot manage this connection" },
                        status: :forbidden
        end

        access = @agent.agent_service_accesses.find_by(service_connection: connection)
        return render json: { error: "Enable this resident's access first" }, status: :conflict if access.nil?

        access.change_send_grant!(can_send, actor: current_api_user)
        audit_human_action(can_send ? :grant_resident_comms_send : :withdraw_resident_comms_send,
                           connection, account: @account, resident_id: @agent.to_param, provider: connection.provider)
        render json: { service_connection: service_connection_json(connection, access) }
      rescue AgentServiceAccess::SendGrantRefused => error
        render json: { error: error.message }, status: :conflict
      end

      private

      def require_residents_enabled!
        return if Setting.instance.allow_agents?

        render json: { error: "Residents are currently disabled" }, status: :forbidden
      end

      # Account-level actions (catalogue, birth): the request's account (the
      # key's, or for an OAuth token the one account_id names, else the
      # person's default), only while it is enabled and they are a confirmed
      # member. Otherwise 404.
      def set_account
        @account = human_account!(requested_account)
        Current.account = @account
      end

      # Home residents only, like the web. Guests are managed at home. An
      # account key reaches its account's residents; an OAuth token reaches
      # residents of every enabled account the person belongs to, or only the
      # account account_id names. Authority then comes from the resident's own
      # account, never a default.
      def set_agent
        @agent = reachable_agents.find(params[:id])
        @account = human_account!(@agent.account)
        Current.account = @account
      end

      def reachable_agents
        return Agent.where(account_id: current_api_user.confirmed_accounts.select(:id)) if app_token_request? && params[:account_id].blank?

        requested_account.agents
      end

      # The web edit page's data, without secrets (the Telegram bot token is
      # never serialized; telegram_configured says whether one is set),
      # without web-only URLs, and without the per-viewer Telegram link token.
      def settings_json
        catalog = @agent.subagent_catalog
        {
          agent: @agent.as_json,
          provisioning: provisioning_json,
          house_allowance: HouseInferenceGrant.find_by(agent: @agent)&.presentation,
          subagent_catalog: catalog.options,
          subagent_providers: catalog.providers,
          subagent_catalog_empty_reason: catalog.empty_reason,
          telegram_subscriber_count: @agent.telegram_subscriptions.active.count,
          service_connections: service_connections_json
        }
      end

      # The web onboarding page's stages, as data an agent can poll.
      def provisioning_json
        setup_failed = @agent.provisioning_failed?
        runtime_ready = @agent.external? && @agent.health_state == "healthy"
        orientation_failed = @agent.orientation_last_error.present?
        orientation_finished = @agent.orientation_completed_at.present?
        state = if setup_failed then "setup_failed"
        elsif orientation_finished then "ready"
        elsif orientation_failed then "orientation_failed"
        elsif runtime_ready then "orienting"
        elsif @agent.provisioning? then "provisioning"
        else @agent.runtime
        end

        {
          state: state,
          settled: setup_failed || orientation_failed || orientation_finished,
          runtime: @agent.runtime,
          health_state: @agent.health_state,
          stages: {
            beginning_recorded: @agent.birth_committed_at.present?,
            home_prepared: @agent.identity_seeded_at.present?,
            runtime_ready: runtime_ready,
            orientation_offered: @agent.orientation_requested_at.present?,
            orientation_completed: orientation_finished
          },
          sandbox_last_error: @agent.sandbox_last_error,
          orientation_last_error: @agent.orientation_last_error,
          can_retry_provisioning: @agent.provisioning_retryable?,
          can_retry_orientation: @agent.orientation_retryable?
        }
      end

      def service_connections_json
        accesses = @agent.agent_service_accesses.index_by(&:service_connection_id)
        @account.service_connections.connected.includes(:connected_by_user).map do |connection|
          service_connection_json(connection, accesses[connection.id])
        end
      end

      def service_connection_json(connection, access)
        connection.as_connection_json(current_user: current_api_user).merge(
          enabled: access&.enabled? || false,
          can_send: access&.can_send? || false,
          provisioning_status: access&.provisioning_status
        )
      end

      def render_invalid(errors)
        render json: { error: errors.full_messages.to_sentence, errors: errors.to_hash }, status: :unprocessable_entity
      end

    end
  end
end
