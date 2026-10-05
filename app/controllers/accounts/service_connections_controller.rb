class Accounts::ServiceConnectionsController < ApplicationController

  before_action :set_connection, only: [ :update, :destroy ]

  def create
    definition = Services::Definition.fetch(params.require(:provider))
    raise ArgumentError, "This service uses OAuth authorization" unless definition.connection_method == "credentials"

    management_scope = params.require(:management_scope)
    authorize_management_scope!(definition, management_scope)
    result = definition.adapter.connection_attributes(
      credentials: credential_params(definition).to_h,
      user: Current.user
    )
    existing = current_account.service_connections.find_by(
      provider: definition.key,
      credential_fingerprint: result.fetch(:credential_fingerprint)
    )
    if existing
      raise Services::AdapterError, "That credential is already connected as #{existing.display_label}"
    end

    connection = current_account.service_connections.new(
      connected_by_user: Current.user,
      provider: definition.key,
      external_subject_id: result.fetch(:external_subject_id),
      external_identity: result[:external_identity],
      label: result[:label],
      management_scope: management_scope,
      credential_kind: result.fetch(:credential_kind),
      credential_fingerprint: result.fetch(:credential_fingerprint),
      credential_metadata: result.fetch(:credential_metadata),
      status: "connected"
    )
    connection.credential_payload_hash = result.fetch(:credential_payload)
    connection.save!

    audit(:connect_service, connection,
          provider: connection.provider,
          management_scope: connection.management_scope,
          external_identity: connection.external_identity,
          authority_summary: connection.credential_metadata["authority_summary"])
    redirect_to account_integrations_path(current_account),
                notice: "#{definition.name} connected"
  rescue Services::Definition::UnknownProvider, Services::AdapterError, KeyError, ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_back_or_to account_integrations_path(current_account), alert: e.message
  end

  def update
    unless @connection.manageable_by?(Current.user)
      redirect_back_or_to account_path(current_account), alert: "You cannot manage this connection"
      return
    end

    attributes = connection_params
    if attributes[:freely_provisionable].present? && !@connection.owner?(Current.user)
      attributes.delete(:freely_provisionable)
    end
    @connection.update!(attributes)
    audit(:update_service_connection, @connection,
          provider: @connection.provider,
          enabled_for_new_agents: @connection.enabled_for_new_agents?,
          freely_provisionable: @connection.freely_provisionable?)
    redirect_back fallback_location: account_integrations_path(current_account), notice: "Service connection updated"
  end

  def destroy
    unless @connection.manageable_by?(Current.user)
      redirect_back_or_to account_path(current_account), alert: "You cannot manage this connection"
      return
    end

    @connection.disconnect!
    audit(:disconnect_service, @connection, provider: @connection.provider)
    @connection.destroy!
    redirect_back fallback_location: account_integrations_path(current_account), notice: "Service disconnected"
  end

  private

  def set_connection
    @connection = current_account.service_connections.find_by_public_id!(params[:id])
  end

  def connection_params
    params.require(:service_connection).permit(:label, :enabled_for_new_agents, :freely_provisionable)
  end

  # Each credentials provider declares its own fields; nothing else passes.
  def credential_params(definition)
    params.require(:credentials).permit(*definition.credential_fields.map { |field| field.fetch("key") })
  end

  def authorize_management_scope!(definition, scope)
    raise ArgumentError, "Unsupported connection ownership" unless definition.supports_management_scope?(scope)

    case scope
    when "personal"
      true
    when "account_managed"
      raise Account::NotAuthorized unless current_account.service_credentials_manageable_by?(Current.user)
    end
  end

end
