class GithubResidentImportsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_import_authority!
  before_action :set_import, only: [ :show, :approve, :refresh, :retry_activation ]

  def new
    render_import
  end

  def show
    render_import
  end

  def create
    attrs = params.require(:github_resident_import).permit(:name, :model_id, :service_connection_id, :branch)
    connection = current_account.service_connections.find_by_public_id!(attrs.delete(:service_connection_id))
    raise Account::NotAuthorized unless connection.provider == "github" && connection.provisionable_by?(Current.user)
    raise ArgumentError, "Choose a supported model" unless (Chat::MODELS + HouseInference::Offering.models).any? { |model| model[:model_id] == attrs[:model_id] }
    Agents::GithubImportSource.new(connection).with_checkout(branch: attrs.delete(:branch)) do |_root, manifest, sha, branch|
      metadata = connection.credential_metadata
      raise ArgumentError, "Credential metadata changed" unless Services::GithubTokenAdapter.fingerprint(connection.credential_payload_hash["token"].to_s) == connection.credential_fingerprint
      # Old or rotated connections cannot lend a new token old scope claims.
      token_metadata = connection_metadata(connection)
      @import = current_account.github_resident_imports.create!(attrs.merge(service_connection: connection,
        requested_by: Current.user, repository: metadata.fetch("repository"), repository_id: metadata.fetch("repository_id"),
        branch: branch, commit_sha: sha, portable_home_id: manifest.fetch("identity_id"),
        credential_fingerprint: connection.credential_fingerprint, token_metadata: token_metadata))
    end
    audit(:request_github_resident_import, @import, repository: @import.repository, commit_sha: @import.commit_sha)
    redirect_to account_github_resident_import_path(current_account, @import), notice: "Import requested. An authorized account manager must approve repository execution."
  rescue Account::NotAuthorized
    head :forbidden
  rescue Agents::GithubImportSource::Error, ActiveRecord::RecordInvalid, ArgumentError, KeyError
    redirect_to new_account_github_resident_import_path(current_account),
      inertia: { errors: { base: [ "Import request failed. Check the fine-grained connection, branch, model and portable_v1 manifest." ] } }
  end

  def approve
    return head :forbidden unless @import.approvable_by?(Current.user)
    raise ArgumentError unless params[:confirmed].to_s == "true"
    @import.approve!(Current.user, review_revision: params[:review_revision])
    audit(:approve_github_resident_import, @import, repository: @import.repository, branch: @import.branch,
      commit_sha: @import.approved_commit_sha, credential_fingerprint: @import.approved_credential_fingerprint,
      approval_scope: "future_pushes_to_this_branch")
    redirect_to account_github_resident_import_path(current_account, @import), notice: "Repository execution approved. Import queued."
  rescue Account::NotAuthorized
    head :forbidden
  rescue ArgumentError, ActiveRecord::RecordInvalid, Agents::GithubImportSource::Error
    redirect_to account_github_resident_import_path(current_account, @import), alert: "Approval failed. Review the current request and credential."
  end

  def retry_activation
    return head :forbidden unless @import.approvable_by?(Current.user)
    @import.retry_activation!(Current.user)
    audit(:retry_github_resident_import_activation, @import)
    redirect_to account_github_resident_import_path(current_account, @import), notice: "Activation retry queued."
  rescue Account::NotAuthorized
    head :forbidden
  rescue ArgumentError, Agent::RuntimeAvailability::Unavailable
    redirect_to account_github_resident_import_path(current_account, @import), alert: "Activation requires valid approval and operator runtime trust."
  end

  def refresh
    @import.refresh_review!(Current.user)
    audit(:refresh_github_resident_import_review, @import, commit_sha: @import.commit_sha)
    redirect_to account_github_resident_import_path(current_account, @import), notice: "Review refreshed. Account approval is required again."
  rescue Account::NotAuthorized
    head :forbidden
  rescue ArgumentError, ActiveRecord::RecordInvalid, Services::AdapterError, Agents::GithubImportSource::Error
    redirect_to account_github_resident_import_path(current_account, @import), alert: "Review refresh failed. Check the connection and existing identity."
  end

  private

  def require_import_authority!
    head :forbidden unless GithubResidentImport.requestable_by?(current_account, Current.user)
  end

  def set_import
    @import = current_account.github_resident_imports.find(params[:id])
  end

  def render_import
    can_manage_import = @import.present? && @import.approvable_by?(Current.user)
    render inertia: "agents/github-import", props: {
      account: current_account.as_json, github_import: import_props,
      connections: current_account.service_connections.connected.where(provider: "github").select { |connection|
        connection.provisionable_by?(Current.user)
      }.map { |connection| { id: connection.public_id, label: connection.display_label,
        repository: connection.credential_metadata["repository"], token_metadata: token_props(connection_metadata(connection)) } },
      models: (Chat::MODELS + HouseInference::Offering.models).map { |model| model.slice(:model_id, :label) },
      submit_url: account_github_resident_imports_path(current_account),
      approve_url: can_manage_import ? approve_account_github_resident_import_path(current_account, @import) : nil,
      refresh_url: can_manage_import ? refresh_account_github_resident_import_path(current_account, @import) : nil,
      retry_activation_url: can_manage_import ? retry_activation_account_github_resident_import_path(current_account, @import) : nil,
      can_approve: can_manage_import,
      future_branch_trust_notice: GithubResidentImport::FUTURE_BRANCH_TRUST_NOTICE,
      runtime_trust_notice: GithubResidentImport::RUNTIME_TRUST_NOTICE
    }
  end

  def import_props
    return unless @import
    connection = @import.service_connection
    current = connection.credential_payload.present? ? Services::GithubTokenAdapter.fingerprint(connection.credential_payload_hash["token"].to_s) : nil
    {
      id: @import.to_param, status: @import.status, name: @import.name, model_id: @import.model_id,
      repository: @import.repository, branch: @import.branch, commit_sha: @import.commit_sha,
      portable_home_id: @import.portable_home_id, home_profile: "portable_v1",
      review_revision: @import.review_revision,
      token_metadata: token_props(@import.token_metadata), approved_commit_sha: @import.approved_commit_sha,
      current_token_metadata: token_props(connection_metadata(connection)),
      credential_fingerprint: @import.credential_fingerprint&.first(12),
      current_credential_fingerprint: current&.first(12),
      approved_credential_fingerprint: @import.approved_credential_fingerprint&.first(12),
      credential_changed: current != @import.credential_fingerprint,
      approved_at: @import.approved_at&.iso8601, approved_by_name: @import.approved_by&.display_name,
      observed_branch_sha_at_approval: @import.observed_branch_sha_at_approval,
      approval_valid: @import.approval_error.nil?, approval_error: @import.approval_error,
      last_error: @import.last_error,
      agent_edit_url: @import.agent ? edit_account_agent_path(current_account, @import.agent) : nil
    }
  end

  def token_props(metadata)
    metadata.slice("token_kind", "oauth_scopes", "authority_source", "authority_summary").merge(
      "token_kind" => metadata["token_kind"] || "unknown",
      "warnings" => Array(metadata["authority_warnings"]))
  end

  def connection_metadata(connection)
    metadata = connection.credential_metadata.to_h
    token = connection.credential_payload_hash["token"]
    reliable = metadata["authority_fingerprint"] == Services::GithubTokenAdapter.fingerprint(token.to_s)
    Services::GithubTokenAdapter.authority_metadata(token).merge(
      reliable ? metadata.slice("oauth_scopes", "authority_source", "authority_summary", "authority_warnings") : {})
  end

end
