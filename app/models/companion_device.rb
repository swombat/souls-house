class CompanionDevice < ApplicationRecord

  include ObfuscatesId

  CREDENTIAL_PREFIX = "shcd_".freeze
  RECOVERY_WINDOW = 60.seconds
  CONTROLS = %w[pause resume revoke].freeze

  class InvalidCredential < StandardError; end
  class Paused < StandardError; end
  class RetryConflict < StandardError; end
  class AboveCeiling < StandardError; end

  ACCESS_RANK = { "off" => 0, "read" => 1, "write" => 2 }.freeze

  belongs_to :account
  belongs_to :companion_enrollment_grant
  has_many :companion_cable_tickets, dependent: :delete_all

  encrypts :session_response
  attr_readonly :account_id, :companion_enrollment_grant_id, :name

  validates :name, presence: true, length: { maximum: 100 }
  validates :credential_digest, presence: true, uniqueness: true
  validates :grant_revision, numericality: { only_integer: true, greater_than: 0 }
  validate :grant_account_matches, on: :create

  def self.generate_credential
    "#{CREDENTIAL_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value)
  end

  def self.credential?(value)
    value.is_a?(String) && value.match?(/\Ashcd_[A-Za-z0-9_-]{43}\z/)
  end

  # Previous credentials are NOT general device authority. Only create_session!
  # accepts them, only to recover the exact previous response.
  def self.authenticate(value)
    return unless credential?(value)

    device = find_by(credential_digest: digest(value), revoked_at: nil)
    device if device&.active?
  end

  def active?
    revoked_at.nil? && !paused? && !account.reload.disabled?
  end

  # The owner's pause, resume or revoke, from the API or the Computers page.
  # Pause and revoke cancel active work and drop the connection. The block
  # runs inside the lock, so the caller's audit row commits with the change.
  def apply_control!(control)
    raise ArgumentError, "unknown control" unless CONTROLS.include?(control)

    device = self
    with_lock do
      if control == "revoke"
        revoke!
      else
        update!(paused: control == "pause")
      end
      unless control == "resume"
        CompanionOperation.where(companion_device: self, state: CompanionOperation::ACTIVE_STATES)
          .update_all(state: "cancelled", outcome: "changed")
        ActiveRecord.after_all_transactions_commit do
          CompanionChannel.broadcast_to(device, { type: control })
          ActionCable.server.remote_connections.where(current_user: nil, current_app_session: nil,
            current_companion_device: device).disconnect(reconnect: false)
        end
      end
      yield if block_given?
    end
  end

  # The owner's switch for one resident's execute/desktop authority on an
  # enrolled device. Volumes are not changed here. The revision bump makes
  # every in-flight operation undeliverable; active ones are cancelled. The
  # device's own local ceiling, scope and switch still apply on top.
  #
  # A nil flag means "leave it as it is": the current value is read under
  # the lock, so a caller that changes one permission (the Computers page)
  # can never write back a stale value for the other.
  def change_resident_authority!(resident_id:, actor:, execute: nil, desktop: nil)
    flags = [ execute, desktop ]
    raise ArgumentError, "booleans required" unless flags.all? { |f| [ true, false, nil ].include?(f) }
    raise ArgumentError, "nothing to change" if flags.all?(&:nil?)

    with_lock do
      raise ArgumentError, "device revoked" if revoked_at
      residents = policy.fetch("residents").map(&:dup)
      resident = residents.find { |r| r["id"] == resident_id }
      raise ArgumentError, "resident not on this device" unless resident
      before = { "execute" => resident["execute"], "desktop" => resident["desktop"] == true }
      execute = before["execute"] if execute.nil?
      desktop = before["desktop"] if desktop.nil?
      after = { "execute" => execute, "desktop" => desktop }
      return false if before == after

      resident["execute"] = execute
      desktop ? resident["desktop"] = true : resident.delete("desktop")
      next_policy = CompanionEnrollmentGrant.normalize_policy(account, { "residents" => residents })
      update!(policy: next_policy, grant_revision: grant_revision + 1)
      AuditLog.create!(user: actor, account: account, auditable: self, action: "companion.device.authority_changed",
        data: { device_id: obfuscated_id, resident_id: resident_id, before: before, after: after,
          grant_revision: grant_revision })
      stop_work_under_old_policy!
      true
    end
  end

  # The owner's change to one folder for one resident: off, read or write.
  # Every other folder and both execute/desktop flags are read under the lock
  # and kept, so a stale page can only change the folder it names.
  #
  # Widening (off to read, anything to write) must stay within the ceiling
  # the companion last reported, and is refused when there is no report.
  # That is a consistency rule, not authority: the report can be stale, and
  # the companion checks every request against its own ceiling. Narrowing is
  # always allowed, including a grant whose folder the report no longer has.
  def change_resident_volume!(resident_id:, volume:, access:, actor:)
    raise ArgumentError, "access must be off, read or write" unless ACCESS_RANK.key?(access)
    raise ArgumentError, "volume required" unless volume.is_a?(String) && volume.present?

    with_lock do
      raise ArgumentError, "device revoked" if revoked_at
      residents = policy.fetch("residents").map { |r| r.merge("volumes" => r.fetch("volumes").map(&:dup)) }
      resident = residents.find { |r| r["id"] == resident_id }
      raise ArgumentError, "resident not on this device" unless resident
      grant = resident["volumes"].find { |v| v["volume"] == volume }
      before = grant ? grant["access"] : "off"
      return false if before == access

      if ACCESS_RANK.fetch(access) > ACCESS_RANK.fetch(before)
        allowed = ceiling_access(resident_id, volume)
        raise AboveCeiling, "above the reported ceiling" if allowed.nil? || ACCESS_RANK.fetch(access) > ACCESS_RANK.fetch(allowed)
      end

      if access == "off"
        resident["volumes"].delete(grant)
      elsif grant
        grant["access"] = access
      else
        resident["volumes"] << { "volume" => volume, "access" => access }
      end
      next_policy = CompanionEnrollmentGrant.normalize_policy(account, { "residents" => residents })
      update!(policy: next_policy, grant_revision: grant_revision + 1)
      AuditLog.create!(user: actor, account: account, auditable: self, action: "companion.device.volume_changed",
        data: { device_id: obfuscated_id, resident_id: resident_id, volume: volume, before: before, after: access,
          grant_revision: grant_revision })
      stop_work_under_old_policy!
      true
    end
  end

  # The companion's report of its local ceiling, from the connection that
  # holds `epoch`. It replaces the previous report whole; a report from a
  # connection that is no longer current, or one that doesn't validate, is
  # dropped. Only residents enrolled on this device are kept, and only volume
  # keys and access. Returns true when stored. Grants are never changed here.
  def record_ceiling_report!(epoch:, claimed_epoch:, ceiling:)
    with_lock do
      return false unless revoked_at.nil? && epoch.present? && connection_epoch == epoch && claimed_epoch == epoch

      report = normalize_ceiling_report(ceiling)
      return false unless report

      update!(reported_ceiling: report, ceiling_reported_at: Time.current, ceiling_epoch: epoch)
      true
    end
  end

  # The access the last report allows, or nil when there is no report or it
  # doesn't mention this resident.
  def ceiling_access(resident_id, volume)
    resident = reported_ceiling&.fetch("residents")&.find { |r| r["id"] == resident_id }
    return unless resident

    resident.fetch("volumes").find { |v| v["volume"] == volume }&.fetch("access") || "off"
  end

  def revoke!(actor: nil)
    with_lock do
      return if revoked_at

      update!(revoked_at: Time.current, connection_epoch: nil, previous_credential_digest: nil,
        session_response: nil, session_request_id: nil, session_retry_until: nil)
      AuditLog.create!(user: actor, account: account, auditable: self, action: "companion.device.revoked",
        data: { device_id: obfuscated_id })
    end
  end

  # Serialize rotations. During recovery, even a new current credential cannot
  # start another rotation with a different request ID: that would silently
  # destroy the outstanding retry's recoverability. Conflicts never revoke.
  def self.create_session!(value, request_id)
    raise InvalidCredential unless credential?(value)
    raise ArgumentError, "request_id must be 1-128 safe characters" unless request_id.is_a?(String) &&
      CompanionEnrollmentGrant::REQUEST_ID.match?(request_id)

    supplied_digest = digest(value)
    device = where(credential_digest: supplied_digest).or(where(previous_credential_digest: supplied_digest)).first
    raise InvalidCredential unless device

    response = device.with_lock do
      raise InvalidCredential unless device.revoked_at.nil? && !device.account.reload.disabled?

      current = ActiveSupport::SecurityUtils.secure_compare(device.credential_digest, supplied_digest)
      previous = device.previous_credential_digest == supplied_digest
      raise InvalidCredential unless current || previous

      recovering = device.session_retry_until && device.session_retry_until > Time.current
      if previous && !recovering
        AuditLog.create!(account: device.account, auditable: device, action: "companion.device.stale_credential",
          data: { device_id: device.obfuscated_id })
        # Refuse outside this transaction, or raising would roll back the audit.
        next nil
      end
      raise InvalidCredential unless current || device.session_request_id == request_id
      if recovering
        if device.session_request_id == request_id &&
            (current || previous)
          return JSON.parse(device.session_response)
        end
        raise Paused if device.paused?
        raise RetryConflict if current
      end
      raise InvalidCredential unless current
      raise Paused if device.paused?
      # Don't reuse a completed request ID for a fresh rotation.
      raise RetryConflict if device.session_request_id == request_id

      next_credential = generate_credential
      ticket_value, ticket = CompanionCableTicket.issue!(device)
      response = {
        "device_id" => device.to_param, "device_credential" => next_credential,
        "cable_ticket" => ticket_value, "policy" => device.policy,
        "revision" => device.grant_revision, "expires_at" => ticket.expires_at.iso8601(3)
      }
      device.update!(
        previous_credential_digest: device.credential_digest,
        credential_digest: digest(next_credential), session_request_id: request_id,
        session_retry_until: RECOVERY_WINDOW.from_now, session_response: JSON.generate(response)
      )
      response
    end
    raise InvalidCredential unless response

    response
  end

  private

  # Work already running on the device holds the old policy. Active
  # operations are cancelled here; dropping the connection cancels what is
  # running there (the companion drains its process workers on connection
  # exit) and it reconnects under the new revision.
  def stop_work_under_old_policy!
    active = CompanionOperation.where(companion_device: self, state: CompanionOperation::ACTIVE_STATES)
    CompanionOperationInput.where(companion_operation_id: active.select(:id)).delete_all
    active.update_all(state: "cancelled", outcome: "changed")
    device = self
    ActiveRecord.after_all_transactions_commit do
      ActionCable.server.remote_connections.where(current_user: nil, current_app_session: nil,
        current_companion_device: device).disconnect(reconnect: true)
    end
  end

  def normalize_ceiling_report(value)
    return unless value.is_a?(Hash) && value.keys == [ "residents" ] && value["residents"].is_a?(Array) &&
      value["residents"].size <= 128

    enrolled = policy.fetch("residents").map { |r| r["id"] }
    seen = []
    total = 0
    residents = value["residents"].filter_map do |resident|
      return unless resident.is_a?(Hash) && resident.keys.sort == %w[id volumes] && resident["id"].is_a?(String) &&
        !seen.include?(resident["id"]) && resident["volumes"].is_a?(Array) && resident["volumes"].size <= 128

      seen << resident["id"]
      keys = []
      volumes = resident["volumes"].map do |grant|
        return unless grant.is_a?(Hash) && grant.keys.sort == %w[access volume] && %w[read write].include?(grant["access"])

        key = grant["volume"]
        return unless key.is_a?(String) && key.bytesize.between?(1, 128) && !key.match?(/[[:cntrl:]]/) && !keys.include?(key)

        keys << key
        { "volume" => key, "access" => grant["access"] }
      end
      next unless enrolled.include?(resident["id"])

      total += volumes.size
      return if total > 128

      { "id" => resident["id"], "volumes" => volumes }
    end
    { "residents" => residents }
  end

  def grant_account_matches
    unless companion_enrollment_grant&.account_id == account_id
      errors.add(:companion_enrollment_grant, "must belong to this account")
    end
  end

end
