# A visitor's seat-holding admission to one account (JdWxAj): the visiting
# agent, the home it claims, and the digest of the visit token that
# authenticates only on /api/v1/visit/*. The home origin is claimed, never
# verified, and is shown as claimed.
#
# Ending it (either side) closes every seat under a lock on this row; a seat
# being created holds the same row FOR SHARE (ChatAgent), as with guests.
class VisitorAdmission < ApplicationRecord

  belongs_to :account
  belongs_to :agent
  belongs_to :visitor_invitation
  has_many :visitor_wakes, dependent: :destroy

  attr_reader :raw_token

  validates :visit_token_digest, presence: true, uniqueness: true
  validates :home_origin, presence: true
  validates :ended_by, inclusion: { in: %w[account visitor] }, allow_nil: true

  scope :current, -> { where(ended_at: nil) }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.authenticate(token)
    return nil if token.blank? || !token.start_with?("visit_")

    current.includes(:agent, :account).find_by(visit_token_digest: digest(token))
  end

  def self.normalize_origin(value)
    uri = URI.parse(value.to_s.strip)
    return nil unless uri.is_a?(URI::HTTPS) && uri.host.present?
    return nil if uri.userinfo || uri.query || uri.fragment || uri.path.to_s.delete_suffix("/").present?

    port = uri.port == 443 ? "" : ":#{uri.port}"
    "https://#{uri.host.downcase}#{port}"
  rescue URI::InvalidURIError
    nil
  end

  def current?
    ended_at.nil?
  end

  def home_host
    URI.parse(home_origin).host
  rescue URI::InvalidURIError
    home_origin
  end

  # The seat is re-checked on every visit request: still admitted, the
  # account still enabled, and seated in this conversation now.
  def seated_in?(chat)
    current? && chat.account_id == account_id && ChatAgent.exists?(chat_id: chat.id, agent_id: agent_id)
  end

  def seated_chats
    account.chats.where(id: ChatAgent.where(agent_id: agent_id).select(:chat_id))
  end

  def end!(by:)
    with_lock do
      return false unless current?

      close_seats
      visitor_wakes.unfinished.find_each(&:expire!)
      agent.update_columns(active: false, updated_at: Time.current)
      update!(ended_at: Time.current, ended_by: by)
    end
    true
  end

  def as_json(*)
    {
      id: to_param,
      agent: { id: agent.to_param, name: agent.name, colour: agent.colour, icon: agent.icon },
      account: { id: account.to_param, name: account.name },
      home: { origin: home_origin, name: home_name, claimed: true },
      state: current? ? "current" : "ended",
      ended_by: ended_by,
      admitted_at: created_at.iso8601,
      last_seen_at: last_seen_at&.iso8601
    }
  end

  def status_json
    as_json.merge(
      seats: seated_chats.order(:id).map { |chat| { conversation_id: chat.to_param, title: chat.title } }
    )
  end

  private

  # Already holding this row FOR UPDATE (end!): a seat in flight
  # (ChatAgent#agent_takes_part_in_account holds it FOR SHARE) has either
  # committed and is closed here, or waits and then finds the visit ended.
  def close_seats
    ChatAgent.where(agent_id: agent_id, chat_id: account.chats.select(:id)).includes(:chat).find_each do |seat|
      chat = seat.chat
      seat.destroy!
      next unless chat.respondable?

      chat.messages.create!(role: "user", content: "[System Notice] #{agent.name} (visiting) has left the conversation.")
    end
  end

end
