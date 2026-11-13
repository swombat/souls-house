class ApiKey < ApplicationRecord

  TOKEN_PREFIX = "hx_"

  belongs_to :user
  belongs_to :account
  belongs_to :agent, optional: true
  has_many :api_key_requests, dependent: :nullify

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true

  scope :by_creation, -> { order(created_at: :desc) }

  # A resident's extra, named keys: any key bound to a resident other than the
  # one the house placed in its container (agents.outbound_api_key_id).
  scope :resident_named, -> {
    where.not(agent_id: nil).where.not(id: Agent.where.not(outbound_api_key_id: nil).select(:outbound_api_key_id))
  }

  def self.generate_for(user, name:, agent: nil, account: agent&.account || user.default_account)
    raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"

    key = create!(
      user: user,
      account: account,
      agent: agent,
      name: name,
      token_digest: Digest::SHA256.hexdigest(raw_token),
      token_prefix: raw_token[0, 8]
    )

    key.define_singleton_method(:raw_token) { raw_token }
    key
  end

  def self.authenticate(token)
    return nil if token.blank?
    key = find_by(token_digest: Digest::SHA256.hexdigest(token))
    key unless key&.agent && !key.agent.hosted?
  end

  def touch_usage!(ip_address)
    update_columns(last_used_at: Time.current, last_used_ip: ip_address)
  end

  def display_prefix
    "#{token_prefix}..."
  end

  def resident_named?
    agent_id.present? && agent&.outbound_api_key_id != id
  end

  # What a resident's message records about the key that posted it. The label
  # is set only for a named key, so the container key's posts stay unmarked.
  def message_attribution
    { api_key_id: id, api_key_label: (name if resident_named?) }
  end

end
