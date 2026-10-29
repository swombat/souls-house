# When a failed roll switches a resident off (ops/deploy/roll-resident.rb sets
# active: false, paused: true rather than let an older runtime run against data
# that may already be migrated), the people of its home account are told, in a
# conversation of its own in Main with the resident in it (a system line wakes
# nobody, and a paused resident takes no turns), and the switch-off gets an
# audit entry.
#
# Before this (#641), Claude was switched off by a failed roll on 28 Oct with no
# audit entry and no notice; the only trace was a red deploy, and a hand repair
# brought his container back while leaving him switched off.
#
# RollHoldWatchJob then says once, in the same conversation, if the resident's
# runtime is healthy again but it is still switched off.
class ResidentSwitchedOffNotice

  SWITCHED_OFF = "resident_switched_off_by_roll".freeze
  STILL_OFF = "resident_roll_hold_still_off".freeze

  def self.switched_off!(agent, image:)
    new(agent).switched_off!(image: image)
  end

  def self.still_off!(hold)
    new(hold.auditable).still_off!(hold)
  end

  def initialize(agent)
    @agent = agent
  end

  def switched_off!(image:)
    Agent.transaction do
      chat = @agent.account.chats.create_with_message!(
        { title: "#{@agent.name} was switched off by a failed update", manual_responses: true },
        agent_ids: [ @agent.id ], automatic_response: false
      )
      at = Time.current
      chat.messages.create!(role: "system", content: switched_off_text(at), notice_link: link)
      AuditLog.create!(user: nil, account: @agent.account, action: SWITCHED_OFF, auditable: @agent,
        data: { image: image.to_s.first(200), chat_id: chat.id, at: at.iso8601 })
    end
  end

  def still_off!(hold)
    chat = Chat.find_by(id: hold.data&.dig("chat_id"), account_id: @agent.account_id)
    Agent.transaction do
      chat ||= @agent.account.chats.create_with_message!(
        { title: "#{@agent.name} is still switched off", manual_responses: true },
        agent_ids: [ @agent.id ], automatic_response: false
      )
      chat.messages.create!(role: "system", content: still_off_text(hold.created_at), notice_link: link)
      AuditLog.create!(user: nil, account: @agent.account, action: STILL_OFF, auditable: @agent,
        data: { hold_id: hold.id, chat_id: chat.id })
    end
  end

  def switched_off_text(at)
    "[System Notice] #{@agent.name} was switched off by a failed house update at #{time_label(at)}. " \
      "#{@agent.name}'s runtime didn't come back healthy on the new image, so the house set #{@agent.name} " \
      "to inactive and paused rather than let an older runtime run against data that may already have moved on. " \
      "#{@agent.name} takes no turns until switched back on. Once the runtime is healthy again, turn Active on " \
      "and Paused off in #{@agent.name}'s settings."
  end

  def still_off_text(since)
    "[System Notice] #{@agent.name}'s runtime is answering health checks again, but #{@agent.name} is still " \
      "switched off since the failed house update at #{time_label(since)}. If the repair is finished, " \
      "turn Active on and Paused off in #{@agent.name}'s settings."
  end

  private

  def link
    { label: "Settings", path: Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "settings") }
  end

  def time_label(at)
    zone = ActiveSupport::TimeZone[@agent.account.owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    at.in_time_zone(zone).strftime("%-d %b %H:%M %Z")
  end

end
