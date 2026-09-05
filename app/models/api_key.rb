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

end
