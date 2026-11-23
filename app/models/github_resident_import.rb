class GithubResidentImport < ApplicationRecord

  include ObfuscatesId

  FUTURE_BRANCH_TRUST_NOTICE = "Approval permits ALL code in this repository, including hooks and sync scripts, and future pushes to this branch to run with the resident's container credentials. Fine-grained token format does not prove least privilege. Revoking approval does not kill already running code or recall copied credentials.".freeze
  STATUSES = %w[pending_review approved provisioning needs_runtime_trust ready failed].freeze
  # Where a site admin chose to make this import's resident. nil: the site
  # setting decides when the import is admitted, as for everyone else.
  PLACEMENTS = %w[main_server own_server].freeze
  RUNTIME_TRUST_NOTICE = "The reviewed home is seeded, but Chaos has no supported headless project-trust grant command. A site operator must open Chaos's interactive trust screen for /home/agent/identity in this resident's own runtime home, then retry activation. Trust the OAuth runtime separately if it is used. No repository hooks, sync scripts or first wake are permitted before trust. Do not copy another resident's database or edit trust/hook tables.".freeze
  # The same rule for a resident on its own server (docs/2026-10-10-vm-imports.md,
  # point 4): its runtime home is on that server, so trust is granted there.
  RUNTIME_TRUST_NOTICE_VM = "The reviewed home is seeded on this resident's own server, which waits for runtime trust. " \
                            "A site operator must open Chaos's interactive trust screen for /home/agent/identity in this " \
                            "resident's runtime home on that server, then retry activation. Trust the OAuth runtime separately " \
                            "if it is used. No repository hooks, sync scripts or first wake are permitted before trust. Do not " \
                            "copy another resident's database or edit trust/hook tables. The " \
                            "server is released if trust is not granted within 45 minutes; the reviewed home is kept and " \
                            "retrying orders a new server, where trust must be granted again.".freeze

  def runtime_trust_notice
    agent&.placement&.kind == "github_import" ? RUNTIME_TRUST_NOTICE_VM : RUNTIME_TRUST_NOTICE
  end

  belongs_to :account
  belongs_to :service_connection
  belongs_to :requested_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  has_one :agent, dependent: :restrict_with_error, inverse_of: :github_resident_import

  validates :name, :model_id, :repository, :repository_id, :branch,
    :commit_sha, :portable_home_id, :credential_fingerprint, presence: true
  validates :name, length: { maximum: 100 }
  validates :status, inclusion: { in: STATUSES }
  validates :sync_strategy, inclusion: { in: %w[existing standard] }
  validates :placement, inclusion: { in: PLACEMENTS }, allow_nil: true
  validate :valid_sync_configuration
  validates :commit_sha, format: { with: /\A[0-9a-f]{40}\z/ }
  validate :connection_matches_account
  validate :reviewed_configuration_is_immutable, on: :update
  validate :home_not_already_held, on: :create

  def self.requestable_by?(account, user)
    account.service_credentials_manageable_by?(user)
  end

  # Whether this import's resident is made on its own server: the site
  # admin's choice when there was one, otherwise the site setting now.
  def own_server?
    placement.nil? ? Agents::VmBirthPolicy.current.enabled? : placement == "own_server"
  end

  # Why a new resident can't be placed where this import goes, or nil. A
  # main-server choice is never refused for the VM switch; an own-server one
  # skips only the switch, never backups, procurement or the server limit.
  def placement_refusal
    Agents::VmBirthPolicy.current.refusal(kind: :import, own_server: own_server?)
  end

  # Why this request can't make a resident: a resident in this account
  # already holds its home (agents.portable_home_id is unique, and a retired
  # resident keeps its home). A sentence a person can act on, or nil. The
  # resident this request itself made is not "another". A holder in another
  # account is never confirmed here: see home_held_elsewhere?.
  def home_holder_error
    holder = home_holder
    return unless holder && holder.account_id == account_id

    if holder.deprecated_at
      "This home is still linked to retired resident #{holder.name}. Contact support if you're trying to recover that resident."
    else
      "This home is already linked to #{holder.name}. To continue with that resident, open the original import request."
    end
  end

  # Whether a resident in another account holds this home. Only the job asks,
  # and it fails with its general message, so a requester can't learn from
  # the form which ids are taken elsewhere.
  def home_held_elsewhere?
    holder = home_holder
    holder.present? && holder.account_id != account_id
  end

  def approvable_by?(user)
    self.class.requestable_by?(account, user) && service_connection.reload.provisionable_by?(user)
  end

  def sync_auto_commit_paths
    sync_configuration.fetch("auto_commit_paths", [])
  end

  def sync_append_only_paths
    sync_configuration.fetch("append_only_paths", [])
  end

  def sync_allow_destructive_paths
    sync_configuration.fetch("allow_destructive_paths", [])
  end

  SYNC_STATES = %w[unknown ok busy blocked needs_attention failed stale].freeze
  SYNC_REASONS = %w[not_recorded runtime_unavailable synced lock_busy staged_changes dirty_worktree
    operation_in_progress wrong_branch invalid_configuration protected_deletion protected_shrink
    append_only_violation commit_failed fetch_failed merge_conflict integration_failed push_failed
    timed_out runner_failed stale].freeze

  def record_sync_health!(data)
    data = {} unless data.is_a?(Hash)
    safe = {
      "state" => data["state"].in?(SYNC_STATES) ? data["state"] : "unknown",
      "reason_code" => data["reason_code"].in?(SYNC_REASONS) ? data["reason_code"] : "not_recorded",
      "rescue_status" => data["rescue_status"].in?(%w[not_needed pushed failed]) ? data["rescue_status"] : "not_needed"
    }
    %w[checked_at last_success_at].each do |key|
      safe[key] = safe_sync_time(data[key])
    end
    safe["last_success_at"] ||= sync_health["last_success_at"]
    ref = data["rescue_ref"]
    safe["rescue_ref"] = ref if ref.is_a?(String) && ref.match?(%r{\Arescue/[A-Za-z0-9_-]{1,48}/[0-9]{8}T[0-9]{12}Z-[a-f0-9]{12}\z})
    safe.merge!(safe_blocking_paths(data))
    update!(sync_health: safe)
  end

  def sync_health_props
    data = sync_health.presence || { "state" => "unknown", "reason_code" => "not_recorded", "rescue_status" => "not_needed" }
    success = safe_sync_time(data["last_success_at"])
    age = success && [ (Time.current - Time.iso8601(success)).to_i, 0 ].max
    props = data.slice("state", "checked_at", "last_success_at", "reason_code", "rescue_ref", "rescue_status")
      .merge("last_success_age_seconds" => age)
    props.merge!(safe_blocking_paths(data))
    props.merge!("state" => "stale", "reason_code" => "stale") if data["state"] == "ok" && (!age || age > 1800)
    props
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
    Agents::GithubImportSource.new(service_connection, sync_strategy: sync_strategy).with_checkout(branch: branch) do |_root, manifest, sha, _branch|
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

  class MoveRefused < StandardError; end

  MOVE_BUSY = "Its server is being worked on right now. Try again in a minute.".freeze
  MOVE_STARTED = "This resident has already started, so moving it is a migration, not a change of import.".freeze
  MOVE_NOT_WAITING = "Only an import that is waiting for approval or runtime trust, or has failed, can be moved.".freeze
  MOVE_HOUSE_HOME = "This import's home is already seeded on the main server. Moving a home to its own server " \
                    "is a migration from the resident's settings.".freeze
  MOVE_SERVER_STATE = "Its own server is past the point where the import can be moved back.".freeze
  MOVE_RELEASING = "Moved to the main server. Its own server is being released; retry activation once it has gone " \
                   "and the home is set up on the main server.".freeze
  MOVED_TO_MAIN_SERVER = "github_import_moved_to_main_server".freeze

  # What a site admin can move this import to now: "main_server",
  # "own_server", or nil. Only a never-started import moves; one that has
  # run is a migration (Agents::VmMigration), never this.
  def movable_to
    if agent.nil?
      return unless status.in?(%w[pending_review failed])
      return own_server? ? "main_server" : "own_server"
    end
    return unless status.in?(%w[needs_runtime_trust failed])

    "main_server" if placement != "main_server" && on_own_server_never_started?
  end

  # A site admin moves a never-started import between the main server and
  # its own server, so it never needs an operator's script (23 Nov, Reed).
  # With no resident yet only the recorded choice changes, and the usual
  # checks run when it is admitted. A resident already admitted to its own
  # server but never started is sent back to the main server: its server's
  # cleanup is requested through the normal path (VmCleanupJob deletes it
  # and retires the placement), and the import records "main_server". Retry
  # activation, once the placement is retired, makes the placement local and
  # seeds the home on the main server from the reviewed checkout
  # (GithubResidentImportJob#bring_home!). Nothing is kept: a server nobody
  # is responsible for is a bill nobody is (Mira, #1109). Returns the
  # destination.
  def move_to!(destination, by:)
    raise Account::NotAuthorized unless by&.is_site_admin?
    raise ArgumentError, "unknown destination" unless PLACEMENTS.include?(destination)

    return move_without_resident!(destination, by:) if agent.nil?
    raise MoveRefused, MOVE_STARTED if agent.runtime_ready_at.present?

    placement_row = agent.placement
    raise MoveRefused, MOVE_HOUSE_HOME unless placement_row&.kind == "github_import"
    raise ArgumentError, "already on its own server" unless destination == "main_server"

    result = ProvisionVmAgentJob.exclusively(placement_row.id) { return_to_main_server!(by:) }
    raise MoveRefused, MOVE_BUSY if result == :busy

    VmCleanupJob.perform_later(placement_row.id)
    destination
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
    Agents::GithubImportSource.new(connection, sync_strategy: sync_strategy).with_checkout(branch: branch) do |_root, manifest, sha, _branch|
      raise ArgumentError, "Portable identity changed" unless manifest["identity_id"] == portable_home_id
      with_lock do
        raise Account::NotAuthorized unless approvable_by?(user)
        raise ArgumentError, "Wait for provisioning to finish" if status.in?(%w[approved provisioning])
        raise ArgumentError, "Credential changed during review" unless service_connection.reload.credential_fingerprint == result[:credential_fingerprint]
        @refreshing_review = true
        update!(commit_sha: sha, credential_fingerprint: result[:credential_fingerprint],
          sync_configuration: sync_strategy == "standard" ? manifest.fetch("standard_sync", {}) : {},
          token_metadata: result[:credential_metadata].slice("token_kind", "oauth_scopes", "authority_source", "authority_summary", "authority_warnings"),
          status: "pending_review", last_error: nil)
      ensure
        @refreshing_review = false
      end
    end
  end

  private

  def moving_placement
    @moving_placement = true
    yield
  ensure
    @moving_placement = false
  end

  # Its own server, never started: still waiting for its first start, or
  # already released (the trust deadline requests cleanup and fails the
  # placement; VmCleanupJob then retires it). Either way it holds no home
  # anyone has run.
  def on_own_server_never_started?(resident = agent, placement_row = resident&.placement)
    placement_row.present? && placement_row.backend == "hetzner_cloud" && placement_row.kind == "github_import" &&
      placement_row.state.in?(%w[pending failed retired]) &&
      resident.runtime_ready_at.nil? && resident.identity_seeded_at.nil? && !resident.active? && resident.paused?
  end

  def move_without_resident!(destination, by:)
    with_lock do
      raise MoveRefused, MOVE_STARTED if agent.present?
      raise MoveRefused, MOVE_NOT_WAITING unless status.in?(%w[pending_review failed])
      from = placement
      moving_placement { update!(placement: destination) }
      AuditLog.create!(action: "github_import_placement_changed", user: by, account:, auditable: self,
        data: { "from" => from, "to" => destination })
    end
    destination
  end

  # Under ProvisionVmAgentJob.exclusively for its placement, so no
  # provisioning step runs against it meanwhile. The placement stays a VM
  # one until VmCleanupJob has retired it; only then does a retry bring the
  # resident home, so the cleanup never loses the server it must delete.
  def return_to_main_server!(by:)
    AgentPlacement.transaction do
      lock!
      resident = Agent.lock.find(agent.id)
      placement_row = AgentPlacement.lock.find_by!(agent_id: resident.id)
      raise MoveRefused, MOVE_STARTED if resident.runtime_ready_at.present?
      raise MoveRefused, MOVE_NOT_WAITING unless status.in?(%w[needs_runtime_trust failed])
      raise MoveRefused, MOVE_SERVER_STATE unless on_own_server_never_started?(resident, placement_row)

      RunnerEnrollment.where(agent_placement_id: placement_row.id, revoked_at: nil).find_each(&:revoke!)
      placement_row.request_cleanup!(MOVED_TO_MAIN_SERVER) unless placement_row.state == "retired"
      from = placement
      moving_placement { update!(placement: "main_server", status: "needs_runtime_trust", last_error: MOVE_RELEASING) }
      AuditLog.create!(action: "github_import_returned_to_house", user: by, account:, auditable: resident,
        data: { "github_resident_import_id" => id, "placement_id" => placement_row.id,
          "generation" => placement_row.generation, "released_provider_server_id" => placement_row.provider_server_id,
          "from" => from })
    end
  end

  def safe_blocking_paths(data)
    return {} unless data["reason_code"] == "dirty_worktree" && data["state"].in?(%w[blocked needs_attention])

    paths = data["blocking_paths"].is_a?(Array) ? data["blocking_paths"] : []
    bounded = paths.first(100)
    safe = bounded.select do |path|
      path.is_a?(String) && path.valid_encoding? && path.length.between?(1, 500) &&
        !path.match?(/[[:cntrl:]\\]/) && !path.start_with?("/", "~") &&
        !path.match?(/\A[A-Za-z]:/) &&
        path.split("/", -1).none? { |part| part.in?(%w[. .. .git]) || part.empty? }
    end.uniq
    { "blocking_paths" => safe,
      "blocking_paths_truncated" => data["blocking_paths_truncated"] == true || paths.size > 100 || safe.size < bounded.size }
  end

  def safe_sync_time(value)
    return unless value.is_a?(String) && value.length <= 40 && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
    Time.iso8601(value).utc.iso8601(6)
  rescue ArgumentError
    nil
  end

  def valid_sync_configuration
    keys = %w[auto_commit_paths append_only_paths allow_destructive_paths]
    config = sync_configuration
    valid = config.is_a?(Hash) && (config.keys - keys).empty?
    if valid
      valid = keys.all? do |key|
        paths = config.fetch(key, [])
        paths.is_a?(Array) && paths.size <= 100 && paths.all? { |path|
          path.is_a?(String) && path.length.between?(1, 1024) &&
            !path.match?(/[\x00-\x1f\\*?\[]/) && !path.start_with?("/") &&
            path.split("/", -1).none? { |part| part.in?(%w[. .. .git]) || part.empty? }
        }
      end
    end
    if valid
      valid = keys.drop(1).all? { |key| config.fetch(key, []).all? { |path|
        config.fetch("auto_commit_paths", []).any? { |scope| path == scope || path.start_with?("#{scope}/") }
      } }
    end
    errors.add(:sync_configuration, "must declare safe literal scopes within auto-commit paths") unless valid
    errors.add(:sync_configuration, "requires standard sync") if sync_strategy == "existing" && config.present?
  end

  def connection_matches_account
    return unless service_connection
    errors.add(:service_connection, "must be a GitHub connection in this account") unless
      service_connection.account_id == account_id && service_connection.provider == "github"
  end

  def home_holder
    holder = Agent.find_by(portable_home_id: portable_home_id) if portable_home_id.present?
    holder unless holder && persisted? && holder.github_resident_import_id == id
  end

  def home_not_already_held
    return if portable_home_id.blank?
    error = home_holder_error
    errors.add(:portable_home_id, error) if error
  end

  def reviewed_configuration_is_immutable
    immutable = %w[account_id service_connection_id requested_by_id name model_id repository repository_id branch portable_home_id sync_strategy]
    immutable += %w[commit_sha credential_fingerprint token_metadata sync_configuration] unless @refreshing_review
    # Where it goes changes only through move_to!, which checks the state first.
    immutable += %w[placement] unless @moving_placement
    if (changes.keys & immutable).any?
      errors.add(:base, "Submit a new request to change reviewed configuration")
    end
  end

end
