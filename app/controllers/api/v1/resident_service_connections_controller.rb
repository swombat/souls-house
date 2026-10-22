module Api
  module V1
    # A resident setting up a service itself (issue #500): "set up a Ghost
    # blog for me and run it" should not end with the person hunting for the
    # Integrations page. Resident keys only, home account only, services that
    # connect from pasted credentials only.
    #
    # What it may touch is decided by the server, never by a parameter:
    # - the person it acts for is the resident key's own person, who must
    #   still be a confirmed member of the resident's account;
    # - it manages (relabel, grant, disconnect) only connections it set up
    #   itself. Anything else, a person's own sign-in included, is 404;
    # - scope is always personal; it cannot make a connection account-managed,
    #   delegable or a default for new residents.
    #
    # The safeguard is a notice, not a gate: every change posts a system line
    # in the conversation it was asked in, linking to Integrations, where a
    # person can disconnect it.
    class ResidentServiceConnectionsController < BaseController

      UNDO_SENTENCE = "Disconnecting it under Integrations removes house access at once; " \
                      "the key itself stays valid at %{provider} until it is rotated or deleted there."

      before_action :require_resident!
      before_action :set_account
      before_action :set_connection, only: %i[update destroy resident_access]

      # GET /api/v1/resident/service_connections/providers
      def providers
        render json: { providers: connectable_definitions.map { |definition| provider_json(definition) } }
      end

      # GET /api/v1/resident/service_connections
      def index
        connections = @account.service_connections.where(connected_by_agent: current_api_agent).order(:id)
        render json: { service_connections: connections.map { |connection| connection_json(connection) } }
      end

      # POST /api/v1/resident/service_connections
      # { provider, label?, credentials: { <field>: value }, conversation_id }
      def create
        definition = Services::Definition.fetch(params.require(:provider))
        unless connectable_definitions.include?(definition)
          return render json: { error: "#{definition.name} needs a person to sign in on the web (Integrations); a resident can't connect it" },
                        status: :unprocessable_entity
        end
        chat = notice_chat!

        # The connection, its grant, the audit row and the notice commit
        # together: no connection without the line that tells people.
        connection = ServiceConnection.transaction do
          connection = ServiceConnection.connect_with_credentials!(
            account: @account,
            user: current_api_user,
            agent: current_api_agent,
            definition: definition,
            management_scope: "personal",
            credentials: credential_params(definition)
          )
          connection.update!(label: params[:label]) if params[:label].present?
          current_api_agent.set_service_access!(connection, enabled: true)
          audit(:connect_service, connection, provider: connection.provider, external_identity: connection.external_identity,
                                              authority_summary: connection.credential_metadata["authority_summary"])
          post_notice(chat, "#{current_api_agent.name} connected #{describe(connection)} for #{current_api_user.display_name}. " \
                            "#{access_sentence(connection)} #{UNDO_SENTENCE % { provider: connection.definition.name }}")
          connection
        end
        render json: { service_connection: connection_json(connection) }, status: :created
      rescue Services::Definition::UnknownProvider => error
        render json: { error: error.message }, status: :not_found
      rescue Services::AdapterError, ActionController::ParameterMissing => error
        render json: { error: error.message }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      # PATCH /api/v1/resident/service_connections/:id  { label }
      def update
        @connection.update!(label: params.require(:label).to_s.strip.presence)
        audit(:update_service_connection, @connection, provider: @connection.provider, label: @connection.label)
        render json: { service_connection: connection_json(@connection) }
      rescue ActionController::ParameterMissing => error
        render json: { error: error.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/resident/service_connections/:id  { conversation_id }
      def destroy
        chat = notice_chat!
        description = describe(@connection)
        provider = @connection.definition.name
        ServiceConnection.transaction do
          @connection.disconnect!
          audit(:disconnect_service, @connection, provider: @connection.provider)
          @connection.destroy! unless @connection.retained_after_disconnect?
          post_notice(chat, "#{current_api_agent.name} disconnected #{description}. Residents no longer get its key from the house, " \
                            "but a copy they already had stays valid at #{provider} until it is rotated or deleted there, " \
                            "and anything already done with it stays done.")
        end
        render json: { disconnected: { id: @connection.public_id, provider: @connection.provider },
                       provider_side: "The key is still valid at #{provider} until it is rotated or deleted there." }
      rescue ActionController::ParameterMissing => error
        render json: { error: error.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/resident/service_connections/:id/residents/:resident_id
      # { enabled, conversation_id }
      def resident_access
        enabled = ActiveModel::Type::Boolean.new.cast(params.require(:enabled))
        resident = @account.agents.find(params[:resident_id])
        if enabled && @connection.status != "connected"
          return render json: { error: "This connection isn't connected; connect it again first" }, status: :conflict
        end
        chat = notice_chat!

        ServiceConnection.transaction do
          resident.set_service_access!(@connection, enabled: enabled)
          audit(enabled ? :enable_resident_service : :disable_resident_service, @connection,
                provider: @connection.provider, resident_id: resident.to_param)
          verb = enabled ? "gave #{resident.name} access to" : "removed #{resident.name}'s access to"
          post_notice(chat, "#{current_api_agent.name} #{verb} #{describe(@connection)}. #{access_sentence(@connection)}")
        end
        render json: { service_connection: connection_json(@connection) }
      rescue ActionController::ParameterMissing => error
        render json: { error: error.message }, status: :unprocessable_entity
      end

      private

      def require_resident!
        return if current_api_agent

        render json: { error: "This endpoint is for a resident's own key; people connect services under /api/v1/account/service_connections" },
               status: :forbidden
      end

      # The resident's home account, and nothing else: a guest account, or any
      # account_id that isn't home, is 404. The key's person must still be a
      # confirmed member, since the connection is recorded as theirs.
      def set_account
        @account = current_api_agent.account
        raise ActiveRecord::RecordNotFound if params[:account_id].present? && params[:account_id].to_s != @account.to_param
        return if current_api_user&.confirmed_accounts&.exists?(@account.id)

        render json: { error: "The person this key belongs to is no longer a member of this account" }, status: :forbidden
      end

      # Only connections this resident set up, from pasted credentials. Every
      # other connection is reported as missing, not forbidden.
      def set_connection
        @connection = @account.service_connections.find_by_public_id!(params[:id])
        raise ActiveRecord::RecordNotFound unless @connection.resident_managed_by?(current_api_agent)
      end

      # Services connected from pasted fields. OAuth sign-ins, QR pairing and
      # field-less sign-ins (Tailscale) need the person themselves.
      def connectable_definitions
        Services::Definition.all.select do |definition|
          definition.connection_method == "credentials" && definition.credential_fields.any? &&
            definition.available? && definition.supports_management_scope?("personal")
        end
      end

      # The conversation the person asked in, which the resident must be in.
      def notice_chat!
        current_api_agent.chats.kept.where(account_id: @account.id).find(params.require(:conversation_id))
      end

      def post_notice(chat, content)
        ResidentConnectionNotice.post!(chat, content, account: @account)
      end

      def describe(connection)
        name = connection.definition.name
        label = connection.display_label
        # Adapters often label with the service already ("Ghost (Lume writes)").
        label.start_with?(name) ? label : "#{name} (#{label})"
      end

      def access_sentence(connection)
        names = connection.agent_service_accesses.enabled.includes(:agent).map { |access| access.agent.name }.sort
        names.any? ? "Residents who can use it: #{names.join(', ')}." : "No resident can use it now."
      end

      def credential_params(definition)
        keys = definition.credential_fields.map { |field| field.fetch("key") }
        raw = params[:credentials]
        raise ActionController::ParameterMissing, :credentials unless raw.respond_to?(:permit)

        raw.permit(*keys).to_h
      end

      def provider_json(definition)
        {
          key: definition.key,
          name: definition.name,
          credential_fields: definition.credential_fields.map { |field| field.slice("key", "label", "type", "help") },
          documentation: definition.documentation
        }
      end

      def connection_json(connection)
        {
          id: connection.public_id,
          provider: connection.provider,
          provider_name: connection.definition.name,
          label: connection.display_label,
          identity: connection.external_identity,
          status: connection.status,
          connected_by_name: connection.connected_by_name,
          authority_summary: connection.credential_metadata.to_h["authority_summary"],
          residents: connection.agent_service_accesses.enabled.includes(:agent).map { |access| { id: access.agent.to_param, name: access.agent.name } }
        }
      end

      def audit(action, connection, **data)
        AuditLog.create!(
          user: current_api_user,
          account: @account,
          action: action,
          auditable: connection,
          data: data.merge(agent_id: current_api_agent.id, api_key_id: @current_api_key&.id, actor: "resident"),
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end

    end
  end
end
