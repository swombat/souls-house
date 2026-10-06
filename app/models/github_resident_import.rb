class GithubResidentImport < ApplicationRecord

  include ObfuscatesId

  FUTURE_BRANCH_TRUST_NOTICE = "Approval permits ALL code in this repository, including hooks and sync scripts, and future pushes to this branch to run with the resident's container credentials. Fine-grained token format does not prove least privilege. Revoking approval does not kill already running code or recall copied credentials.".freeze
  STATUSES = %w[pending_review approved provisioning needs_runtime_trust ready failed].freeze
  RUNTIME_TRUST_NOTICE = "The reviewed home is seeded, but Chaos has no supported headless project-trust grant command. A site operator must open Chaos's interactive trust screen for /home/agent/identity in this resident's own runtime home, then retry activation. Trust the OAuth runtime separately if it is used. No repository hooks, sync scripts or first wake are permitted before trust. Do not copy another resident's database or edit trust/hook tables.".freeze

  belongs_to :account
  belongs_to :service_connection
  belongs_to :requested_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  has_one :agent, dependent: :restrict_with_error, inverse_of: :github_resident_import

  validates :name, :model_id, :repository, :repository_id, :branch,
    :commit_sha, :portable_home_id, :credential_fingerprint, presence: true
  validates :name, length: { maximum: 100 }
  validates :status, inclusion: { in: STATUSES }
  validates :commit_sha, format: { with: /\A[0-9a-f]{40}\z/ }
  validate :connection_matches_account
  validate :reviewed_configuration_is_immutable, on: :update

  def self.requestable_by?(account, user)
    account.service_credentials_manageable_by?(user)
  end

  def approvable_by?(user)
    self.class.requestable_by?(account, user) && service_connection.reload.provisionable_by?(user)
  end

  def approval_error
    return "Current account approval is required" unless approved_at && approved_by &&
      status.in?(%w[approved provisioning needs_runtime_trust ready])
    return "Approver no longer has permission to manage this account and provision its GitHub connection" unless
      approvable_by?(approved_by)
    connection = service_connection.reload
    metadata = connection.credential_metadata.to_h
    token = connection.credential_payload_hash["token"].to_s
    return "GitHub connection is no longer connected" unless connection.status == "connected"
    return "GitHub credential changed; refresh this request for review" unless connection.credential_fingerprint == approved_credential_fingerprint &&
      approved_credential_fingerprint == credential_fingerprint &&
      Services::GithubTokenAdapter.fingerprint(token) == approved_credential_fingerprint
    return "GitHub repository configuration changed" unless connection.account_id == account_id &&
      connection.provider == "github" && metadata["repository"] == repository &&
      metadata["repository_id"].to_s == repository_id &&
      token.start_with?("github_pat_")
    return "Reviewed revision changed" unless approved_commit_sha == commit_sha
    if agent
      return "Resident runtime configuration changed" unless agent.account_id == account_id &&
        agent.home_profile == "portable_v1" && agent.portable_home_id == portable_home_id &&
        agent.github_repo_url == "https://github.com/#{repository}" &&
        "#{agent.github_repo_owner}/#{agent.github_repo_name}" == repository
    end
    nil
  end

  def require_approval!
    error = approval_error
    raise Agent::RuntimeAvailability::Unavailable.new(error, code: "github_import_approval_required") if error
  end

  def review_revision
    updated_at.iso8601(6)
  end

  def approve!(user, review_revision:)
    raise Account::NotAuthorized unless approvable_by?(user)
    observed_sha = nil
    Agents::GithubImportSource.new(service_connection).with_checkout(branch: branch) do |_root, manifest, sha, _branch|
      raise ArgumentError, "Portable identity changed" unless manifest["identity_id"] == portable_home_id
      observed_sha = sha
    end
    with_lock do
      raise Account::NotAuthorized unless approvable_by?(user)
      raise ArgumentError, "Review changed; reload before approving" unless self.review_revision == review_revision
      raise ArgumentError, "This import is already approved; use activation retry after operator trust" unless status.in?(%w[pending_review failed])
      connection = service_connection.reload
      raise ArgumentError, "GitHub credential or repository changed; refresh this request" unless
        connection.status == "connected" && connection.credential_fingerprint == credential_fingerprint &&
        Services::GithubTokenAdapter.fingerprint(connection.credential_payload_hash["token"].to_s) == credential_fingerprint &&
        connection.credential_metadata["repository"] == repository &&
        connection.credential_metadata["repository_id"].to_s == repository_id &&
        connection.credential_payload_hash["token"].to_s.start_with?("github_pat_")
      update!(approved_by: user, approved_at: Time.current, approved_commit_sha: commit_sha,
        observed_branch_sha_at_approval: observed_sha,
        approved_credential_fingerprint: credential_fingerprint, approved_image: approved_image.presence || Agents::Config.default_image,
        status: "approved", last_error: nil)
      GithubResidentImportJob.perform_later(id)
    end
  end

  def retry_activation!(user)
    raise Account::NotAuthorized unless approvable_by?(user)
    with_lock do
      raise Account::NotAuthorized unless approvable_by?(user)
      raise ArgumentError, "This home is not waiting for runtime trust" unless status == "needs_runtime_trust"
      require_approval!
      update!(status: "approved", last_error: nil)
      GithubResidentImportJob.perform_later(id)
    end
  end

  def refresh_review!(user)
    raise Account::NotAuthorized unless approvable_by?(user)
    raise ArgumentError, "Wait for provisioning to finish" if status.in?(%w[approved provisioning])
    connection = service_connection.reload
    # Refresh provider-reported scope metadata rather than reusing an old
    # token's metadata after rotation. Nothing sensitive is returned to the UI.
    result = connection.definition.adapter.connection_attributes(
      credentials: { "token" => connection.credential_payload_hash["token"], "repository" => repository }, user: user)
    raise ArgumentError, "Only fine-grained-format tokens are supported" unless result.dig(:credential_metadata, "token_kind") == "fine_grained"
    Agents::GithubImportSource.new(connection).with_checkout(branch: branch) do |_root, manifest, sha, _branch|
      raise ArgumentError, "Portable identity changed" unless manifest["identity_id"] == portable_home_id
      with_lock do
        raise Account::NotAuthorized unless approvable_by?(user)
        raise ArgumentError, "Wait for provisioning to finish" if status.in?(%w[approved provisioning])
        raise ArgumentError, "Credential changed during review" unless service_connection.reload.credential_fingerprint == result[:credential_fingerprint]
        @refreshing_review = true
        update!(commit_sha: sha, credential_fingerprint: result[:credential_fingerprint],
          token_metadata: result[:credential_metadata].slice("token_kind", "oauth_scopes", "authority_source", "authority_summary", "authority_warnings"),
          status: "pending_review", last_error: nil)
      ensure
        @refreshing_review = false
      end
    end
  end

  private

  def connection_matches_account
    return unless service_connection
    errors.add(:service_connection, "must be a GitHub connection in this account") unless
      service_connection.account_id == account_id && service_connection.provider == "github"
  end

  def reviewed_configuration_is_immutable
    immutable = %w[account_id service_connection_id requested_by_id name model_id repository repository_id branch portable_home_id]
    immutable += %w[commit_sha credential_fingerprint token_metadata] unless @refreshing_review
    if (changes.keys & immutable).any?
      errors.add(:base, "Submit a new request to change reviewed configuration")
    end
  end

end
