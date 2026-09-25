class DeviceStream < ApplicationRecord

  class Rejected < StandardError

    attr_reader :status

    def initialize(message, status = :unprocessable_entity)
      @status = status
      super(message)
    end

  end

  MAX_BATCHES = 2_000_000
  MAX_SESSIONS = 1_000
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  belongs_to :account
  belongs_to :subject_user, class_name: "User"
  has_many :device_stream_credentials, dependent: :destroy
  has_many :device_stream_sessions, dependent: :destroy
  has_many :device_stream_batches, through: :device_stream_sessions

  before_validation -> { self.stream_key ||= SecureRandom.hex(16) }
  validates :name, presence: true, length: { maximum: 100 }
  validates :stream_key, presence: true, uniqueness: true

  def subject_active?
    account.reload.disabled_at.nil? &&
      account.memberships.where(user_id: subject_user_id).where.not(confirmed_at: nil).exists?
  end

  def readable_by?(user:, agent: nil)
    return false if erased_at? || !subject_active?
    if agent
      agent.active? && agent.account_id == account_id && reader_agent_ids.include?(agent.id)
    else
      account.memberships.where(user: user).where.not(confirmed_at: nil).exists? &&
        (user.id == subject_user_id || reader_user_ids.include?(user.id))
    end
  end

  # All append, revoke, erase and permission mutations serialize on this row.
  def configure!(user_ids:, agent_ids:, enabled:)
    with_lock do
      raise Rejected.new("Stream erased", :gone) if erased_at?
      users = account.memberships.where.not(confirmed_at: nil).pluck(:user_id)
      agents = account.agents.pluck(:id)
      raise Rejected, "Readers must belong to this account" unless
        (user_ids - users).empty? && (agent_ids - agents).empty?
      update!(reader_user_ids: user_ids.uniq, reader_agent_ids: agent_ids.uniq, enabled: enabled)
    end
  end

  def issue_credential!
    with_lock do
      ensure_ingestible!
      raise Rejected, "Revoke old credentials first" if device_stream_credentials.where(revoked_at: nil).count >= 5
      token = "shd_#{SecureRandom.hex(32)}"
      device_stream_credentials.create!(token_digest: Digest::SHA256.hexdigest(token))
      token
    end
  end

  def revoke_credential!(id)
    with_lock { device_stream_credentials.find(id).update!(revoked_at: Time.current) }
  end

  def erase_session!(uuid)
    validate_session_uuid!(uuid)
    with_lock do
      session = session_for!(uuid)
      removed = session.device_stream_batches.delete_all
      update!(batches_count: batches_count - removed)
      session.update!(erased_at: Time.current)
    end
  end

  # Permanent bulk erasure also closes ingestion; a new stream requires a new token.
  def erase!
    with_lock do
      DeviceStreamBatch.where(device_stream_session_id: device_stream_sessions.select(:id)).delete_all
      device_stream_sessions.update_all(erased_at: Time.current)
      device_stream_credentials.update_all(revoked_at: Time.current)
      update!(erased_at: Time.current, enabled: false, reader_user_ids: [], reader_agent_ids: [], batches_count: 0)
    end
  end

  def append!(credential, payload)
    normalized = normalize_payload(payload)
    digest = Digest::SHA256.hexdigest(JSON.generate(normalized))
    with_lock do
      ensure_ingestible!
      unless credential.device_stream_id == id && credential.reload.revoked_at.nil?
        raise Rejected.new("Invalid device credential", :unauthorized)
      end
      session = session_for!(normalized.fetch("session_id"))
      raise Rejected.new("Session erased", :gone) if session.erased_at?
      existing = session.device_stream_batches.find_by(sequence: normalized.fetch("sequence"))
      if existing
        raise Rejected.new("Sequence already used for different data", :conflict) unless existing.payload_digest == digest
        return :ok
      end
      raise Rejected.new("Stream capacity reached", :payload_too_large) if batches_count >= MAX_BATCHES
      if device_stream_batches.where("device_stream_batches.created_at > ?", 1.minute.ago).count >= 600
        raise Rejected.new("Upload rate exceeded; retry later", :too_many_requests)
      end
      session.device_stream_batches.create!(
        sequence: normalized.fetch("sequence"), observed_at: normalized.fetch("observed_at"),
        rr_ms: normalized.fetch("rr_ms"), payload_digest: digest
      )
      update!(batches_count: batches_count + 1)
      :created
    end
  end

  private

  def ensure_ingestible!
    raise Rejected.new("Stream erased", :gone) if erased_at?
    raise Rejected.new("Stream disabled or subject membership inactive", :forbidden) unless enabled? && subject_active?
  end

  def session_for!(uuid)
    device_stream_sessions.find_by(session_uuid: uuid) || begin
      raise Rejected.new("Session capacity reached", :payload_too_large) if device_stream_sessions.count >= MAX_SESSIONS
      device_stream_sessions.create!(session_uuid: uuid)
    end
  end

  def validate_session_uuid!(uuid)
    raise Rejected, "session_id must be a lowercase UUID" unless uuid.is_a?(String) && UUID.match?(uuid)
  end

  def normalize_payload(payload)
    unless payload.is_a?(Hash) && payload.keys.sort == %w[observed_at rr_ms schema sequence session_id]
      raise Rejected, "Expected only schema, session_id, sequence, observed_at and rr_ms"
    end
    raise Rejected, "Unsupported schema" unless payload["schema"] == "rr.v1"
    validate_session_uuid!(payload["session_id"])
    sequence = payload["sequence"]
    raise Rejected, "Invalid sequence" unless sequence.is_a?(Integer) && sequence.between?(0, 9_007_199_254_740_991)
    rr = payload["rr_ms"]
    unless rr.is_a?(Array) && rr.length.between?(1, 256) &&
        rr.all? { |v| v.is_a?(Numeric) && v.finite? && v > 0 && v <= 65_535 * 1000.0 / 1024 }
      raise Rejected, "Invalid RR intervals"
    end
    value = payload["observed_at"]
    unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      raise Rejected, "observed_at requires an ISO8601 timezone"
    end
    observed = Time.iso8601(value).utc
    raise Rejected, "observed_at is in the future" if observed > 5.minutes.from_now
    {
      "schema" => "rr.v1", "session_id" => payload["session_id"], "sequence" => sequence,
      "observed_at" => observed.iso8601(6), "rr_ms" => rr.map(&:to_f)
    }
  rescue ArgumentError
    raise Rejected, "Invalid observed_at"
  end

end
