# A resident hosted in one account and present as a guest in another.
#
# Adding needs someone who belongs to both accounts: the resident's hosting
# account and the receiving one. Leaving needs only one side: the receiving
# account, the hosting account, or the resident itself. Leaving closes the
# guest's seats in the receiving account's rooms; their messages stay.
class GuestMembership < ApplicationRecord

  belongs_to :account
  belongs_to :agent
  belongs_to :added_by, class_name: "User", optional: true

  validates :agent_id, uniqueness: { scope: :account_id }
  validate :not_hosted_here
  validate :added_by_belongs_to_both_accounts, on: :create

  before_destroy :close_seats

  # Residents this user may bring into the account as guests: active residents
  # hosted in the user's other accounts, not already present. Membership is
  # checked directly, with no site-admin shortcut, because the question is
  # whether this person can speak for the resident's home.
  def self.candidates_for(account:, user:)
    return Agent.none unless user && member?(user, account)

    Agent.eligible_for_conversation
      .where(account_id: user.confirmed_accounts.enabled.where.not(id: account.id).select(:id))
      .where.not(id: account.guest_memberships.select(:agent_id))
  end

  def self.member?(user, account)
    user.confirmed_accounts.enabled.exists?(account.id)
  end

  # An owner of either account may end it; the resident may also leave
  # through its own key (Api::V1::GuestMembershipsController).
  def removable_by?(user)
    account.owned_by?(user) || agent.account.owned_by?(user)
  end

  def as_json(*)
    {
      id: to_param,
      agent: { id: agent.to_param, name: agent.name, colour: agent.colour, icon: agent.icon },
      account: { id: account.to_param, name: account.name },
      home_account: { id: agent.account.to_param, name: agent.account.name },
      added_at: created_at.iso8601
    }
  end

  private

  def not_hosted_here
    errors.add(:agent, "is already hosted in this account") if agent && agent.account_id == account_id
  end

  def added_by_belongs_to_both_accounts
    return if added_by && account && agent &&
      self.class.member?(added_by, account) && self.class.member?(added_by, agent.account)

    errors.add(:base, "Only someone who belongs to both the resident's home and this account can add them as a guest")
  end

  # Lock first: an admission in flight holds this row FOR SHARE (see
  # ChatAgent#agent_takes_part_in_account), so we wait for its seat to commit
  # and then close it with the rest.
  def close_seats
    lock!
    ChatAgent.where(agent_id: agent_id, chat_id: account.chats.select(:id)).includes(:chat).find_each do |seat|
      chat = seat.chat
      seat.destroy!
      next unless chat.respondable?

      chat.messages.create!(role: "user", content: "[System Notice] #{agent.name} has left the conversation.")
    end
  end

end
