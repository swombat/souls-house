class AgentServiceAccess < ApplicationRecord

  class SendGrantRefused < StandardError; end

  class ReadGrantRefused < StandardError

    attr_reader :status

    def initialize(message, status: :forbidden)
      @status = status
      super(message)
    end

  end

  # A home decision (approve, decline, revoke) that no longer applies to the
  # request in front of the person: it was answered, it changed, it expired.
  class HomeApprovalRefused < StandardError

    attr_reader :status

    def initialize(message, status: :conflict)
      @status = status
      super(message)
    end

  end

  # Guest integration grants (JWblqj). A row whose resident is hosted where
  # the connection lives stays not_required for good. A guest's row is born
  # pending and grants nothing until the resident's home approves it; the
  # other states explain a row that is switched off (declined, revoked by the
  # home, withdrawn by the sharing side, expired unanswered). A guest row that
  # is switched on is only ever pending or approved.
  HOME_APPROVALS = %w[not_required pending approved declined revoked withdrawn expired].freeze
  OPEN_HOME_APPROVALS = %w[pending approved].freeze
  # An unanswered request is housekeeping, not a boundary (pending grants
  # nothing), so it is closed after this long on its own requested_at.
  REQUEST_EXPIRY = 14.days

  # The one question every reader of a grant asks (the token broker, the
  # comms endpoints, the read proxy, the manifest, the resident's connection
  # list, both Integrations pages): may this resident use this connection
  # now. Hosted: switched on. Guest: switched on, a current guest where the
  # connection lives, and approved by the home. not_required never
  # authorises a foreign row; enabled alone never authorises a guest.
  HOSTED_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM agents hosts
      JOIN service_connections hosted ON hosted.id = agent_service_accesses.service_connection_id
      WHERE hosts.id = agent_service_accesses.agent_id AND hosts.account_id = hosted.account_id
    )
  SQL
  GUEST_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM guest_memberships seats
      JOIN service_connections shared ON shared.id = agent_service_accesses.service_connection_id
      WHERE seats.agent_id = agent_service_accesses.agent_id AND seats.account_id = shared.account_id
    )
  SQL
  EFFECTIVE_SQL = "((agent_service_accesses.home_approval = 'not_required' AND #{HOSTED_SQL}) " \
                  "OR (agent_service_accesses.home_approval = 'approved' AND #{GUEST_SQL}))".freeze

  belongs_to :agent
  belongs_to :service_connection
  belongs_to :home_approval_by, class_name: "User", optional: true

  # Who is changing this row, when a person is (set by set_service_access!
  # and change_send_grant!). Recorded in the send grant history.
  attr_accessor :send_grant_actor

  validates :service_connection_id, uniqueness: { scope: :agent_id }
  validates :home_approval, inclusion: { in: HOME_APPROVALS }
  validate :hosted_or_guest
  validate :home_approval_matches_origin
  validate :can_send_only_through_change_send_grant

  scope :enabled, -> { where(enabled: true) }
  scope :effective, -> { enabled.where(EFFECTIVE_SQL) }
  scope :sending, -> { effective.where(can_send: true) }
  scope :awaiting_home_approval, -> { enabled.where(home_approval: "pending") }

  # No revival (WhatsApp spec §5): set_service_access! reuses this row and
  # changes only `enabled`, so a disabled row loses can_send here, whoever
  # disables it. Re-enabling read never restores it.
  before_validation :withdraw_send_when_disabled
  before_save :withdraw_send_when_disabled
  after_save :record_send_withdrawal_on_disable

  # Commit callbacks are deduplicated by filter name. Keep distinct wrapper
  # methods here so create, update, and destroy reconciliation all survive.
  after_create_commit :schedule_reconciliation_after_create!
  # A send grant changes the resident's manifest (its send endpoint); a home
  # decision changes whether the connection is in it at all.
  after_update_commit :schedule_reconciliation_after_update!,
                      if: -> { saved_change_to_enabled? || saved_change_to_can_send? || saved_change_to_home_approval? }
  after_destroy_commit :schedule_reconciliation_after_destroy!

  after_save :refresh_integration_status, if: :integration_status_changed?
  after_destroy :refresh_integration_status

  # The home's owners see waiting requests as a black notice beside the
  # account menu (ExpiredProviderSubscriptions#awaiting). The navbar reloads
  # that summary on its Account stream, so a request arriving, or being
  # decided, reaches an owner who is already looking at the house without a
  # page load (Daniel, 2026-11-02, JVvkmJ: "I had to look around to find this").
  after_commit :broadcast_home_approval_notice, on: [ :create, :update ], if: :saved_change_to_home_approval?
  # A waiting request also leaves the count when its row goes: the guest
  # leaves the sharing house, or the shared connection is deleted (Mira,
  # #732 review). Distinct name: commit callbacks are deduplicated by filter.
  after_destroy_commit :broadcast_home_approval_notice_after_destroy, if: -> { home_approval == "pending" }

  INTEGRATION_STATUS_COLUMNS = %w[
    agent_id service_connection_id enabled follows_default
    provisioning_status provisioning_error_code home_approval
  ].freeze

  # The connection lives in another house, where the resident is a guest.
  def foreign?
    agent.account_id != service_connection.account_id
  end

  def guest_seat_present?
    GuestMembership.exists?(agent_id: agent_id, account_id: service_connection.account_id)
  end

  # The instance form of the `effective` scope; keep the two in step.
  def effective?
    return false unless enabled?

    foreign? ? home_approval == "approved" && guest_seat_present? : home_approval == "not_required"
  end

  def schedule_reconciliation!
    return unless agent&.externally_hosted? && agent.container_name.present?

    if persisted?
      status = effective? ? "pending" : "removal_pending"
      changed = provisioning_status != status || provisioning_error_code.present?
      written = update_columns(
        provisioning_status: status,
        provisioning_error_code: nil,
        updated_at: Time.current
      )
      refresh_integration_status if written && changed
    end
    AccountAgentCredentialsRefreshJob.perform_later(agent.account_id, agent.id, manifest_only: true)
  end

  def mark_provisioned!
    update!(
      provisioned_revision: service_connection.credential_revision,
      provisioned_at: Time.current,
      provisioning_status: "provisioned",
      provisioning_error_code: nil
    )
  end

  # Grants or withdraws sending as the connection's owner. Only the owner can
  # grant (speaking as a person is that person's grant to give): account
  # admins, freely_provisionable and enabled_for_new_agents confer nothing.
  # Anyone who can manage the connection can withdraw. Every change is
  # recorded.
  #
  # Lock order, the same everywhere a grant is set or cleared (here,
  # Agent#set_service_access!, ServiceConnection#withdraw_send_grants and
  # CommsSending): the connection's row first, then the access row. Owner,
  # status, gate and enabled are all read after both locks are held, so a
  # concurrent owner change, disconnect, re-pair or disable either commits
  # first (and this sees it) or waits for this to commit (and then
  # withdraws what this granted).
  def change_send_grant!(can_send, actor:)
    can_send = ActiveModel::Type::Boolean.new.cast(can_send)
    connection = service_connection
    connection.transaction do
      connection.lock!
      lock!
      unless connection.send_grant_changeable_by?(actor, can_send: can_send)
        raise SendGrantRefused, can_send ? "Only the connection's owner can let a resident send" : "You cannot manage this connection"
      end
      next if self.can_send == can_send

      if can_send
        raise SendGrantRefused, "Sending is not available for this connection" unless CommsSending.available_for?(connection)
        raise SendGrantRefused, "Enable this resident's access first" unless enabled?
        raise SendGrantRefused, "Reconnect this service before letting a resident send" unless connection.status == "connected"
      end
      @granting_send = can_send
      begin
        update!(can_send: can_send)
      ensure
        @granting_send = false
      end
      CommsSendGrantEvent.record!(self, granted: can_send, actor: actor, reason: can_send ? "granted" : "withdrawn")
      # For a guest, speaking as the owner is a widening of what the home
      # approved: it goes back to the home as a new request. Taking it away
      # narrows the grant and keeps the approval.
      if foreign?
        if can_send
          request_home_approval!(actor: actor, reason: "send_granted")
        elsif home_approval == "approved"
          update_columns(home_approval_authority: home_approval_authority.to_h.merge("can_send" => false), updated_at: Time.current)
        end
      end
    end
    self
  end

  # What a home approval is an approval of. A later change to any of it
  # (owner, Google identity, scopes or products, sending) is a different
  # request. A plain re-auth of the same identity with the same authority
  # keeps the approval.
  def self.authority_snapshot(connection, can_send:)
    {
      "owner_user_id" => connection.connected_by_user_id,
      "external_subject_id" => connection.external_subject_id,
      "management_scope" => connection.management_scope,
      "granted_scopes" => Array(connection.granted_scopes).map(&:to_s).sort,
      "effective_authority" => connection.effective_authority.to_h,
      "can_send" => can_send
    }
  end

  def current_authority_snapshot
    self.class.authority_snapshot(service_connection, can_send: can_send?)
  end

  # The approval no longer covers what the connection now carries. Losing
  # sending is a narrowing and does not count.
  def home_approval_stale?
    return false unless foreign?

    stored = home_approval_authority.to_h
    current = current_authority_snapshot
    return true if current["can_send"] && !stored["can_send"]

    stored.except("can_send") != current.except("can_send")
  end

  # The sharing side switched a guest on, or what it shares changed: a fresh
  # request to the home, which grants nothing until approved. Callers hold
  # the connection's lock and this row's.
  def request_home_approval!(actor:, reason: "requested")
    self.enabled = true
    self.home_approval = "pending"
    self.home_approval_requested_at = Time.current
    self.home_approval_at = nil
    self.home_approval_by = nil
    self.home_approval_generation += 1
    self.home_approval_authority = current_authority_snapshot
    save!
    GuestAccessApprovalEvent.record!(self, action: "requested", actor: actor, reason: reason)
    self
  end

  # The sharing side switched a guest off: access stops and the approval is
  # void, whatever state it was in. Switching on again is a new request.
  def withdraw_home_approval!(actor:)
    was = home_approval
    self.enabled = false
    self.home_approval = "withdrawn"
    save!
    if was.in?(OPEN_HOME_APPROVALS)
      GuestAccessApprovalEvent.record!(self, action: "withdrawn", actor: actor,
                                       reason: was == "approved" ? "access_disabled" : "request_withdrawn")
    end
    self
  end

  # The home answers the request it was shown (generation). A request that
  # was answered, withdrawn, changed or expired in the meantime is refused
  # rather than approved by a stale button. A refusal that moves the row
  # (expiry, re-asking with changed authority) commits before it is raised;
  # raising inside the transaction would roll that move back.
  #
  # Lock order (as change_send_grant!): the connection first, then this
  # row. A change to the connection's authority holds the connection's row
  # until it commits (ServiceConnection#re_request_guest_approvals runs
  # inside that UPDATE), so a decision either sees the change, and re-asks,
  # or commits first and is then re-asked by it.
  def approve_home!(actor:, generation:)
    refusal = transaction do
      lock_connection_then_row!
      next refusal if (refusal = refusal_for(generation))

      update!(home_approval: "approved", home_approval_at: Time.current, home_approval_by: actor)
      GuestAccessApprovalEvent.record!(self, action: "approved", actor: actor)
      nil
    end
    raise refusal if refusal
    self
  end

  def decline_home!(actor:, generation:)
    refusal = transaction do
      lock_connection_then_row!
      next refusal if (refusal = refusal_for(generation))

      update!(enabled: false, home_approval: "declined", home_approval_at: Time.current, home_approval_by: actor)
      GuestAccessApprovalEvent.record!(self, action: "declined", actor: actor)
      nil
    end
    raise refusal if refusal
    self
  end

  # The home takes an approval back: access stops, and the sharing side
  # cannot restore it without a new approval.
  def revoke_home!(actor:)
    transaction do
      lock_connection_then_row!
      raise HomeApprovalRefused, "This access is not approved" unless enabled? && home_approval == "approved"

      update!(enabled: false, home_approval: "revoked", home_approval_at: Time.current, home_approval_by: actor)
      GuestAccessApprovalEvent.record!(self, action: "revoked", actor: actor)
    end
    self
  end

  # The sweeper selected this row as an old request; read under the locks,
  # a request renewed since (withdrawn and asked again) is a new one and
  # keeps its own fourteen days.
  def expire_home!
    transaction do
      lock_connection_then_row!
      next unless enabled? && home_approval_expired?

      update!(enabled: false, home_approval: "expired")
      GuestAccessApprovalEvent.record!(self, action: "expired", actor: nil)
    end
    self
  end

  def home_approval_expired?
    home_approval == "pending" && home_approval_requested_at.present? && home_approval_requested_at < REQUEST_EXPIRY.ago
  end

  def home_approval_json
    {
      home_approval: home_approval,
      home_approval_generation: home_approval_generation,
      home_approval_requested_at: home_approval_requested_at&.utc&.iso8601,
      home_approval_at: home_approval_at&.utc&.iso8601,
      home_approval_by_name: home_approval_by&.display_name,
      effective: effective?
    }
  end

  private

  def lock_connection_then_row!
    service_connection.lock!
    lock!
  end

  # Why a decision on this row cannot be taken now, or nil. Called under the
  # row's lock; may move the row (expire it, or re-ask) and returns the
  # refusal to raise once that move has committed.
  def refusal_for(generation)
    return HomeApprovalRefused.new("This request is no longer open") unless enabled? && home_approval == "pending"
    unless generation.to_i == home_approval_generation
      return HomeApprovalRefused.new("This request changed since you saw it. Look at it again before deciding.")
    end
    if home_approval_expired?
      update!(enabled: false, home_approval: "expired")
      GuestAccessApprovalEvent.record!(self, action: "expired", actor: nil)
      return HomeApprovalRefused.new("This request expired unanswered; the sharing side can ask again")
    end
    unless guest_seat_present?
      return HomeApprovalRefused.new("#{agent.name} is no longer a guest in #{service_connection.account.name}", status: :not_found)
    end
    return unless home_approval_stale?

    # The connection changed under the request. Re-ask with what it carries
    # now, and let the person see that before deciding.
    request_home_approval!(actor: nil, reason: "authority_changed")
    HomeApprovalRefused.new("What this connection shares changed since the request. Look at it again before deciding.")
  end

  def withdraw_send_when_disabled
    return unless !enabled? && can_send?

    self.can_send = false
    @send_withdrawn_by_disable = persisted? && can_send_in_database
  end

  def record_send_withdrawal_on_disable
    return unless @send_withdrawn_by_disable

    @send_withdrawn_by_disable = false
    CommsSendGrantEvent.record!(self, granted: false, actor: send_grant_actor || Current.user, reason: "access_disabled")
  end

  # can_send becomes true only inside change_send_grant!, under its locks
  # and checks. Any other write that tries (a mass assignment, a default
  # access, a resident's own call) is invalid.
  def can_send_only_through_change_send_grant
    return unless can_send?

    errors.add(:can_send, "can only be granted by the connection's owner") if will_save_change_to_can_send? && !@granting_send
    errors.add(:can_send, "needs enabled access") unless enabled?
    errors.add(:can_send, "is only for comms connections") unless service_connection&.credential_strategy == "connector"
  end

  def integration_status_changed?
    previously_new_record? || (saved_changes.keys & INTEGRATION_STATUS_COLUMNS).any?
  end

  def refresh_integration_status
    agent_ids = [ agent_id, *saved_change_to_agent_id ].compact
    connection_ids = [ service_connection_id, *saved_change_to_service_connection_id ].compact
    IntegrationStatus.refresh!(
      Agent.where(id: agent_ids).pluck(:account_id) +
        ServiceConnection.where(id: connection_ids).pluck(:account_id)
    )
  end

  def broadcast_home_approval_notice
    return unless foreign?

    broadcast_home_notice_to(agent.account_id)
  end

  # The row is gone, so don't reload what it points at: a guest row is the
  # only kind that is ever pending, and its agent (in memory when the agent
  # itself is being destroyed) names the home account.
  def broadcast_home_approval_notice_after_destroy
    broadcast_home_notice_to(agent&.account_id)
  end

  def broadcast_home_notice_to(account_id)
    account = account_id && Account.find_by(id: account_id)
    return unless account

    ActionCable.server.broadcast(
      "Account:#{account.obfuscated_id}",
      { action: "refresh", prop: "expired_subscriptions" }
    )
  end

  def schedule_reconciliation_after_create!
    schedule_reconciliation!
  end

  def schedule_reconciliation_after_update!
    schedule_reconciliation!
  end

  def schedule_reconciliation_after_destroy!
    schedule_reconciliation!
  end

  # Hosted where the connection lives, or a current guest there.
  def hosted_or_guest
    return unless agent && service_connection
    return if agent.account_id == service_connection.account_id || guest_seat_present?

    errors.add(:service_connection, "must belong to the resident's account, or to an account where it is a guest")
  end

  # A hosted row never carries an approval state; a guest row always does,
  # is never a default, and is only switched on while pending or approved.
  def home_approval_matches_origin
    return unless agent && service_connection

    if agent.account_id == service_connection.account_id
      errors.add(:home_approval, "does not apply to a resident hosted here") unless home_approval == "not_required"
    else
      errors.add(:home_approval, "is required for a guest") if home_approval == "not_required"
      errors.add(:follows_default, "never reaches a guest") if follows_default?
      errors.add(:enabled, "needs a pending or approved request") if enabled? && !home_approval.in?(OPEN_HOME_APPROVALS)
    end
  end

end
