require "test_helper"

class Agents::ResidentActivityTest < ActiveSupport::TestCase
  test "fourteen UTC days separate runs and outbound channels without leaking other residents" do
    agent = agents(:research_assistant)
    other = agents(:other_account_agent)
    now = Time.utc(2026, 9, 7, 12)
    [ [ agent, "wake", now ], [ agent, "memory_aggregation_daily", now ],
      [ agent, "conversation", now ], [ agent, "telegram", now ],
      [ agent, "orientation", now ], [ other, "wake", now ],
      [ agent, "wake", now - 15.days ], [ agent, "wake", Time.utc(2026, 8, 25) ] ].each do |resident, kind, time|
      AgentRuntimeInteraction.create!(agent: resident, trigger_kind: kind, started_at: time)
    end
    AgentRuntimeInteraction.create!(agent: agent, trigger_kind: "wake", started_at: now, runtime_status: "already_running")
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Resident chart")
    Message.create!(chat: chat, agent: agent, role: "assistant", content: "A posted message", created_at: now)
    Message.create!(chat: chat, agent: agent, role: "assistant", content: nil, created_at: now)
    Message.create!(chat: chat, user: users(:user_1), role: "user", content: "Incoming", created_at: now)
    subscription = agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 123)
    [ [ "assistant", "Resident", 1 ], [ "user", "Human", 2 ], [ "assistant", "souls.house", 3 ], [ "assistant", "Resident", nil ] ].each do |role, name, id|
      subscription.telegram_messages.create!(role: role, sender_name: name, text: "Message", telegram_message_id: id, sent_at: now)
    end
    Time.use_zone("Pacific/Auckland") do
      rows = Agents::ResidentActivity.new([ agent ], now: now).call
      assert_equal [ agent.id ], rows.keys
      days = rows.fetch(agent.id)
      assert_equal 14, days.length
      assert_equal "2026-08-25", days.first[:date]
      assert_equal 1, days.first[:heartbeat]
      assert_equal({ date: "2026-09-07", heartbeat: 1, memory: 1, chat: 2, other: 1, conversation: 1, telegram: 1 }, days.last)
    end
  end
end
