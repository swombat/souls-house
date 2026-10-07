require "test_helper"
require "ostruct"

class GuestTelegramNotificationTest < ActiveSupport::TestCase

  setup do
    @shared_member = users(:existing_user)
    @home = accounts(:another_team)
    @nexus = accounts(:team_account)
    fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub(:post, fake_ok) do
      @home.agents.create!(name: "Guest resident", telegram_bot_token: "123:ABC", telegram_bot_username: "guest_bot")
    end
    @nexus.guest_memberships.create!(agent: @agent, added_by: @shared_member)
    @agent.telegram_subscriptions.create!(user: @shared_member, telegram_chat_id: 111)
  end

  test "home and guest chat creation and activity never enqueue Telegram notifications" do
    [ @home, @nexus ].each do |account|
      assert_no_enqueued_jobs only: TelegramNotificationJob do
        chat = account.chats.create!(model_id: "openrouter/auto", manual_responses: true, title: "Room", agents: [ @agent ])
        chat.messages.create!(role: "assistant", agent: @agent, content: "Resident reply")
        chat.messages.create!(role: "user", user: @shared_member, content: "Human reply")
        chat.update!(title: "Updated room")
      end
    end
  end

end
