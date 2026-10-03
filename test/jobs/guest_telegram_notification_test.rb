require "test_helper"
require "ostruct"

# A resident's bot subscribers are members of its home account. When the
# resident speaks in a guest account, only subscribers who can read that
# account may receive the room title and message preview.
class GuestTelegramNotificationTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @shared_member = users(:existing_user)        # member of both the home team and Nexus
    @home_only = users(:regular_user)      # home only
    @home = accounts(:another_team)
    @nexus = accounts(:team_account)
    @home.memberships.create!(user: @home_only, role: "member", confirmed_at: Time.current)

    @sent = []
    @fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub(:post, @fake_ok) do
      @home.agents.create!(name: "Lume", telegram_bot_token: "123:ABC", telegram_bot_username: "lume_bot")
    end
    @nexus.guest_memberships.create!(agent: @agent, added_by: @shared_member)

    @both_sub = @agent.telegram_subscriptions.create!(user: @shared_member, telegram_chat_id: 111)
    @home_sub = @agent.telegram_subscriptions.create!(user: @home_only, telegram_chat_id: 222)

    @guest_room = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, title: "Nexus secret", agents: [ @agent ])
    @guest_message = @guest_room.messages.create!(role: "assistant", agent: @agent, content: "Only for Nexus")
  end

  test "guest-room notifications are queued only for subscribers who can read that account" do
    assert_enqueued_jobs 1, only: TelegramNotificationJob do
      @agent.notify_subscribers!(@guest_message, @guest_room)
    end
    assert_enqueued_with(job: TelegramNotificationJob, args: [ @both_sub, @guest_message, @guest_room ])
  end

  test "a home-only subscriber is sent nothing from a guest room even if a job reaches them" do
    deliveries { TelegramNotificationJob.perform_now(@home_sub, @guest_message, @guest_room) }
    assert_empty @sent
  end

  test "a subscriber who can read the guest account still gets the notification" do
    deliveries { TelegramNotificationJob.perform_now(@both_sub, @guest_message, @guest_room) }
    assert_equal 1, @sent.size
    assert_includes @sent.first, "Nexus secret"
  end

  test "access lost between queueing and delivery stops the send" do
    @agent.notify_subscribers!(@guest_message, @guest_room)
    @nexus.memberships.where(user: @shared_member).delete_all

    deliveries { perform_enqueued_jobs(only: TelegramNotificationJob) }
    assert_empty @sent
  end

  test "home rooms still notify home-only subscribers" do
    home_room = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, title: "Home", agents: [ @agent ])
    message = home_room.messages.create!(role: "assistant", agent: @agent, content: "At home")

    assert_enqueued_jobs 2, only: TelegramNotificationJob do
      @agent.notify_subscribers!(message, home_room)
    end
  end

  private

  def deliveries(&)
    sender = ->(_uri, body, *_rest) { @sent << body.to_s; @fake_ok }
    Net::HTTP.stub(:post, sender, &)
  end

end
