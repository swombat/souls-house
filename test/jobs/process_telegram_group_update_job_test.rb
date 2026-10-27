require "test_helper"
require "ostruct"

# #596: a resident's bot answers in a Telegram group only when the owner has
# allowed the group, and only to messages addressed to it.
class ProcessTelegramGroupUpdateJobTest < ActiveSupport::TestCase

  GROUP_ID = -100_555

  setup do
    @account = accounts(:personal_account)
    @fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub :post, @fake_ok do
      @account.agents.create!(
        name: "Group Agent",
        telegram_bot_token: "4242:ABC",
        telegram_bot_username: "group_bot",
        runtime: "external",
        endpoint_url: "https://agent.example.com",
        trigger_bearer_token: "tr_valid"
      )
    end
  end

  test "being added to a group records it, switched off" do
    assert_difference -> { @agent.telegram_groups.count }, 1 do
      ProcessTelegramUpdateJob.perform_now(@agent, membership_update("member"))
    end

    group = @agent.telegram_groups.sole
    assert_equal "MGL", group.title
    assert_not group.allowed?
    assert_nil group.user
    assert_not group.deliverable?
    assert_equal 0, @agent.telegram_subscriptions.count, "a group is not a subscriber"
  end

  test "a mention in a group nobody allowed records the group and keeps nothing" do
    assert_no_difference "TelegramMessage.count" do
      assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
        ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot hello", mention_entity("@group_bot hello")))
      end
    end
    assert @agent.telegram_groups.exists?(telegram_chat_id: GROUP_ID)
  end

  test "in an allowed group a mention of the bot is kept, named as its sender, and wakes the resident" do
    group = allowed_group

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot what time is it?", mention_entity("@group_bot what time is it?")))
    end

    message = group.telegram_messages.sole
    assert_equal "user", message.role
    assert_equal "Ana Ruiz", message.sender_name
    assert_equal "ana_r", message.sender_username
    assert_equal 77, message.sender_telegram_user_id
    assert_equal "@group_bot what time is it?", message.text
  end

  test "a reply to one of the bot's own messages qualifies and keeps its target" do
    group = allowed_group
    update = group_message("yes please", [], reply_to: { "message_id" => 900, "from" => { "id" => 4242, "is_bot" => true } })

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    assert_equal 900, group.telegram_messages.sole.reply_to_telegram_message_id
  end

  test "a text_mention of the bot qualifies" do
    group = allowed_group
    entity = [ { "type" => "text_mention", "offset" => 0, "length" => 5, "user" => { "id" => 4242 } } ]

    ProcessTelegramUpdateJob.perform_now(@agent, group_message("Lumen, hi", entity))
    assert_equal 1, group.telegram_messages.count
  end

  test "group messages not addressed to the bot are dropped before persistence" do
    group = allowed_group
    other_reply = { "message_id" => 901, "from" => { "id" => 12, "is_bot" => false } }
    cases = [
      group_message("plain chatter"),
      group_message("hey @group_bot_fan look", mention_entity("hey @group_bot_fan look", "@group_bot_fan")),
      group_message("I told @group_bot about it", []),
      group_message("agreed", [], reply_to: other_reply),
      group_message("/reset@group_bot", [ { "type" => "bot_command", "offset" => 0, "length" => 16 } ])
    ]

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      cases.each_with_index do |update, index|
        update["message"]["message_id"] = 100 + index
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end
    assert_equal 0, group.telegram_messages.count
  end

  test "mention offsets are UTF-16 code units, as Telegram counts them" do
    group = allowed_group
    text = "🙂🙂 @group_bot ping"
    entity = [ { "type" => "mention", "offset" => 5, "length" => 10 } ]

    ProcessTelegramUpdateJob.perform_now(@agent, group_message(text, entity))
    assert_equal 1, group.telegram_messages.count
  end

  test "another bot mentioning ours is ignored" do
    group = allowed_group
    update = group_message("@group_bot ping", mention_entity("@group_bot ping"))
    update["message"]["from"]["is_bot"] = true

    ProcessTelegramUpdateJob.perform_now(@agent, update)
    assert_equal 0, group.telegram_messages.count
  end

  test "a Telegram retry of the same update is kept once and wakes once" do
    group = allowed_group
    update = group_message("@group_bot once", mention_entity("@group_bot once"))

    ProcessTelegramUpdateJob.perform_now(@agent, update)
    ProcessTelegramUpdateJob.perform_now(@agent, update.deep_dup)

    assert_equal 1, group.telegram_messages.count
    assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == "TelegramAgentTriggerJob" }
  end

  test "being removed from a group switches it off; being added back does not switch it on" do
    group = allowed_group

    ProcessTelegramUpdateJob.perform_now(@agent, membership_update("kicked"))
    group.reload
    assert_not group.allowed?
    assert group.removed_at
    assert_not group.deliverable?

    ProcessTelegramUpdateJob.perform_now(@agent, membership_update("member"))
    group.reload
    assert_nil group.removed_at
    assert_not group.allowed?, "re-adding the bot needs the owner again"
  end

  test "a group upgraded to a supergroup keeps its record and allowance" do
    group = allowed_group
    update = group_message(nil)
    update["message"].delete("text")
    update["message"]["migrate_to_chat_id"] = -100_999

    ProcessTelegramUpdateJob.perform_now(@agent, update)
    assert_equal(-100_999, group.reload.telegram_chat_id)
    assert group.allowed?
  end

  test "a direct message still goes to the subscriber path, not a group" do
    user = users(:user_1)
    @agent.telegram_subscriptions.create!(user: user, telegram_chat_id: 456)
    update = group_message("hello")
    update["message"]["chat"] = { "id" => 456, "type" => "private" }

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    assert_equal 0, @agent.telegram_groups.count
  end

  private

  def allowed_group
    group = @agent.telegram_groups.create!(telegram_chat_id: GROUP_ID, title: "MGL")
    group.allow!(by: users(:user_1))
    group
  end

  def membership_update(status)
    {
      "update_id" => 1,
      "my_chat_member" => {
        "chat" => { "id" => GROUP_ID, "type" => "supergroup", "title" => "MGL" },
        "from" => { "id" => 77, "first_name" => "Ana" },
        "date" => Time.current.to_i,
        "old_chat_member" => { "status" => "left", "user" => { "id" => 4242 } },
        "new_chat_member" => { "status" => status, "user" => { "id" => 4242 } }
      }
    }
  end

  def group_message(text, entities = [], reply_to: nil)
    message = {
      "message_id" => 10,
      "date" => Time.current.to_i,
      "chat" => { "id" => GROUP_ID, "type" => "supergroup", "title" => "MGL" },
      "from" => { "id" => 77, "is_bot" => false, "first_name" => "Ana", "last_name" => "Ruiz", "username" => "ana_r" },
      "text" => text
    }
    message["entities"] = entities if entities.any?
    message["reply_to_message"] = reply_to if reply_to
    { "update_id" => 2, "message" => message }
  end

  def mention_entity(text, handle = "@group_bot")
    [ { "type" => "mention", "offset" => text.index(handle), "length" => handle.length } ]
  end

end
