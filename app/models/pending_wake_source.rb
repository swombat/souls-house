# One thing that asked for a PendingWake. See PendingWake for why a wake is
# held. A source stands while what gave it authority still does:
#
# - a message: not discarded, and its author still a confirmed member of the
#   room's account (as MessageDispatch requires of a mention), or, for a
#   resident's handoff (MessageHandoff), its author still in the room, as
#   for that resident's knock;
# - a trigger by a person: still a confirmed member of the room's account;
# - a trigger by a resident (a sibling's knock): still in the room.
#
# A source whose requester row has gone (nullified) no longer stands.
class PendingWakeSource < ApplicationRecord

  KINDS = %w[message trigger].freeze

  belongs_to :pending_wake
  belongs_to :message, optional: true
  belongs_to :user, optional: true
  belongs_to :requester_agent, class_name: "Agent", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :message, presence: true, if: -> { kind == "message" }

  def standing?(chat)
    case kind
    when "message"
      return false unless message.present? && !message.reload.discarded?

      return member?(message.user, chat) unless message.role == "assistant" && message.agent_id

      chat.agents.exists?(message.agent_id)
    when "trigger"
      if requester_agent
        chat.agents.exists?(requester_agent.id)
      else
        member?(user, chat)
      end
    else
      false
    end
  end

  private

  def member?(person, chat)
    person.present? && person.confirmed_accounts.exists?(chat.account_id)
  end

end
