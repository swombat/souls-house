class ServiceAuthorizationsController < ApplicationController

  skip_before_action :set_current_account, only: :callback

  def create
    definition = Services::Definition.fetch(params.require(:provider))
    raise ArgumentError, "This service uses direct credential entry" unless definition.connection_method == "oauth2"

    management_scope = params.require(:management_scope)
    authorize_management_scope!(management_scope)
    connection = connection_for_reauthorization(definition, management_scope)

    attempt, state = ServiceAuthorizationAttempt.begin!(
      account: current_account,
      user: Current.user,
      provider: definition.key,
      management_scope: management_scope,
      access_profile: params[:access_profile],
      authority_selection: authority_selection_from_params,
      service_connection: connection,
      return_path: return_path_for(management_scope)
    )
    if connection
      connection.begin_reauthorization!
      audit(:reauthorize_service, connection,
            provider: connection.provider,
            requested_authority: attempt.authority_selection)
    end

    redirect_to definition.adapter.authorization_url(
      attempt,
      state: state,
      redirect_uri: service_authorization_callback_url
    ), allow_other_host: true
  rescue Services::Definition::UnknownProvider, Services::AdapterError, KeyError, JSON::ParserError,
         ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_back_or_to account_personal_services_path(current_account), alert: e.message
  end

  def callback
    attempt = ServiceAuthorizationAttempt.resolve!(params[:state])
    raise ActiveRecord::RecordNotFound unless attempt.user_id == Current.user.id
    Current.account = attempt.account

    if params[:error].present?
      attempt.consume!
      redirect_to attempt.return_path, alert: "Authorization was denied"
      return
    end

    result = attempt.definition.adapter.exchange_code(
      code: params.require(:code),
      attempt: attempt,
      redirect_uri: service_authorization_callback_url
    )

    connection = persist_connection!(attempt, result)
    attempt.consume!
    audit(:connect_service, connection,
          provider: connection.provider,
          management_scope: connection.management_scope,
          granted_scopes: connection.granted_scopes)
    redirect_to attempt.return_path, notice: "#{attempt.definition.name} connected"
  rescue ActiveRecord::RecordNotFound, ActionController::ParameterMissing
    redirect_to root_path, alert: "Invalid or expired authorization"
  rescue Services::AdapterError => e
    redirect_to attempt&.return_path || root_path, alert: e.message
  end

  private

  def authorize_management_scope!(scope)
    case scope
    when "personal"
      true
    when "account_managed"
      raise Account::NotAuthorized unless current_account.service_credentials_manageable_by?(Current.user)
    else
      raise ArgumentError, "Unsupported connection ownership"
    end
  end

  def return_path_for(scope)
    scope == "account_managed" ?
      account_services_path(current_account) :
      account_personal_services_path(current_account)
  end

  def persist_connection!(attempt, result)
    connection = if attempt.service_connection
      expected_subject = attempt.service_connection.external_subject_id
      if expected_subject.present? && expected_subject != result.fetch(:external_subject_id)
        raise Services::AdapterError, "Please reconnect the same Google identity"
      end
      attempt.service_connection
    elsif result[:match_existing_by] == :connected_user
      attempt.account.service_connections.find_or_initialize_by(
        provider: attempt.provider,
        connected_by_user: attempt.user
      )
    else
      attempt.account.service_connections.find_or_initialize_by(
        provider: attempt.provider,
        external_subject_id: result.fetch(:external_subject_id)
      )
    end

    if connection.persisted? && connection.connected_by_user_id != attempt.user_id
      raise Services::AdapterError, "That external identity is already connected by another account member"
    end
    if connection.persisted? && attempt.definition.structured_authority? && attempt.service_connection.nil?
      raise Services::AdapterError, "That Google identity is already connected; edit its access instead"
    end

    connection.connected_by_user = attempt.user
    connection.external_subject_id = result.fetch(:external_subject_id)
    connection.external_identity = result[:external_identity]
    connection.label ||= result[:external_identity]
    connection.management_scope = attempt.management_scope
    connection.credential_kind = result.fetch(:credential_kind)
    connection.credential_payload_hash = result.fetch(:credential_payload)
    connection.credential_metadata = result.fetch(:credential_metadata)
    connection.status = "connected"
    connection.credential_revision += 1 if connection.persisted?
    connection.save!
    connection
  end

  def authority_selection_from_params
    value = params[:authority_selection]
    return nil if value.blank?
    value.is_a?(String) ? JSON.parse(value) : value.to_unsafe_h
  end

  def connection_for_reauthorization(definition, management_scope)
    return nil if params[:service_connection_id].blank?
    raise ArgumentError, "This service does not support access editing" unless definition.structured_authority?

    connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ArgumentError, "Service connection does not match provider" unless connection.provider == definition.key
    raise ArgumentError, "Service connection ownership does not match" unless connection.management_scope == management_scope
    raise Account::NotAuthorized unless connection.manageable_by?(Current.user)
    connection
  end

end
