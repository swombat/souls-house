require "test_helper"
require "ostruct"

# #596: a resident's bot answers in a Telegram group only once the group is
# on, and only to messages addressed to it; while on, the rest of the group's
# conversation is kept as context. A group switches on at an owner's first
# word to the bot there, or from settings.
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

  test "group messages not addressed to the bot are kept as context and wake nobody" do
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
    assert_equal 5, group.telegram_messages.count
    assert group.telegram_messages.none?(&:addressed?)
    assert_equal "Ana Ruiz", group.telegram_messages.first.sender_name
  end

  test "a mention after untagged chatter wakes the resident, which marks only the mention as addressed" do
    group = allowed_group
    chatter = group_message("the contract says 30 days")
    chatter["message"]["message_id"] = 1
    ProcessTelegramUpdateJob.perform_now(@agent, chatter)

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot what do you think of that?", mention_entity("@group_bot what do you think of that?")))
    end
    assert_equal [ false, true ], group.telegram_messages.order(:id).map(&:addressed?)
  end

  test "untagged media in a group that is on is prepared without waking or answering" do
    group = allowed_group
    update = group_message(nil)
    update["message"].delete("text")
    update["message"]["photo"] = [ { "file_id" => "ph1", "width" => 10, "height" => 10, "file_size" => 100 } ]

    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end
    assert_not group.telegram_messages.sole.addressed?
  end

  test "oversized untagged media is marked failed without a word in the group" do
    group = allowed_group
    update = group_message(nil)
    update["message"].delete("text")
    update["message"]["photo"] = [ { "file_id" => "ph1", "width" => 10, "height" => 10, "file_size" => 500.megabytes } ]

    Net::HTTP.stub :post, ->(*) { flunk "nothing may be sent to the group" } do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    message = group.telegram_messages.sole
    assert_equal "failed", message.media_status
    assert_equal "too_large", message.media_error
  end

  test "an owner's first mention switches the group on, announces it, and is answered" do
    link_owner_telegram
    ProcessTelegramUpdateJob.perform_now(@agent, membership_update("member"))
    group = @agent.telegram_groups.sole
    assert_not group.allowed?

    assert_enqueued_with(job: TelegramGroupNoticeJob, args: [ group ]) do
      assert_enqueued_with(job: TelegramAgentTriggerJob) do
        ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot hi", mention_entity("@group_bot hi")))
      end
    end
    group.reload
    assert group.allowed?
    assert_equal users(:user_1), group.allowed_by
    assert group.telegram_messages.sole.addressed?
  end

  test "a linked owner's untagged chatter does not switch the group on" do
    link_owner_telegram
    assert_no_difference "TelegramMessage.count" do
      ProcessTelegramUpdateJob.perform_now(@agent, group_message("just talking"))
    end
    assert_not @agent.telegram_groups.sole.allowed?
  end

  test "a mention from someone who is not a linked owner does not switch the group on" do
    @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 5_555)
    ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot hi", mention_entity("@group_bot hi")))

    assert_not @agent.telegram_groups.sole.allowed?
  end

  test "a group an owner switched off in settings stays off when the owner mentions the bot" do
    link_owner_telegram
    group = allowed_group
    group.disallow!

    assert_no_enqueued_jobs only: [ TelegramGroupNoticeJob, TelegramAgentTriggerJob ] do
      ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot hi", mention_entity("@group_bot hi")))
    end
    assert_not group.reload.allowed?
  end

  test "after the bot is removed and added back, the owner's first mention switches it on again" do
    link_owner_telegram
    group = allowed_group
    ProcessTelegramUpdateJob.perform_now(@agent, membership_update("kicked"))
    ProcessTelegramUpdateJob.perform_now(@agent, membership_update("member"))
    assert_nil group.reload.allowed_at

    ProcessTelegramUpdateJob.perform_now(@agent, group_message("@group_bot back", mention_entity("@group_bot back")))
    assert group.reload.allowed?
  end

  test "mention offsets are UTF-16 code units, as Telegram counts them" do
    group = allowed_group
    text = "🙂🙂 @group_bot ping"
    entity = [ { "type" => "mention", "offset" => 5, "length" => 10 } ]

    ProcessTelegramUpdateJob.perform_now(@agent, group_message(text, entity))
    assert_equal 1, group.telegram_messages.count
  end

  test "another bot mentioning ours is kept as context but never wakes it" do
    group = allowed_group
    update = group_message("@group_bot ping", mention_entity("@group_bot ping"))
    update["message"]["from"]["is_bot"] = true

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    assert_not group.telegram_messages.sole.addressed?
  end

  test "enabled bot answers accept a tag, text mention and reply" do
    group = allowed_group
    group.update!(answers_bots: true)
    text_mention = [ { "type" => "text_mention", "offset" => 0, "length" => 5, "user" => { "id" => 4242 } } ]
    updates = [
      bot_message(101),
      bot_message(102, "Lumen, hi", text_mention),
      bot_message(103, "yes please", [], reply_to: { "message_id" => 900, "from" => { "id" => 4242, "is_bot" => true } })
    ]

    updates.each do |update|
      assert_enqueued_with(job: TelegramAgentTriggerJob) do
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end
    assert_equal 3, group.reload.bot_wake_streak
    assert group.telegram_messages.all?(&:addressed?)
  end

  test "bot answers never accept bare names, untagged text or a tag of another bot" do
    group = allowed_group
    group.update!(answers_bots: true, bot_wake_streak: 2)
    updates = [
      bot_message(101, "Group Agent?"),
      bot_message(102, "plain chatter"),
      bot_message(103, "@group_bot hi", []),
      bot_message(104, "@other_bot hi", mention_entity("@other_bot hi", "@other_bot")),
      bot_message(105, "yes", [], reply_to: { "from" => { "id" => 999 } })
    ]

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      updates.each { |update| ProcessTelegramUpdateJob.perform_now(@agent, update) }
    end
    assert_equal 5, group.telegram_messages.count
    assert group.telegram_messages.none?(&:addressed?)
    assert_equal 2, group.reload.bot_wake_streak, "bot context must not reset a streak"
  end

  test "only listed bot usernames can wake when a list is configured" do
    group = allowed_group
    group.update!(answers_bots: true, answer_bot_usernames: [ "@Other_Bot" ])
    allowed = bot_message(101)
    allowed["message"]["from"]["username"] = "OTHER_BOT"
    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, allowed)
    end

    unlisted = bot_message(102)
    unlisted["message"]["from"]["username"] = "unlisted_bot"
    unnamed = bot_message(103)
    unnamed["message"]["from"].delete("username")
    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      [ unlisted, unnamed ].each { |update| ProcessTelegramUpdateJob.perform_now(@agent, update) }
    end
    assert_equal [ true, false, false ], group.telegram_messages.order(:id).map(&:addressed?)
    assert_equal 1, group.reload.bot_wake_streak
  end

  test "bots with no username may wake when the list is empty" do
    group = allowed_group
    group.update!(answers_bots: true)
    update = bot_message(101)
    update["message"]["from"].delete("username")

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    assert_equal 1, group.reload.bot_wake_streak
  end

  test "a bot cannot auto-enable a group even with an owner's linked Telegram id" do
    link_owner_telegram
    group = @agent.telegram_groups.create!(telegram_chat_id: GROUP_ID, answers_bots: true)
    update = bot_message(101)
    update["message"]["from"]["id"] = 77

    assert_no_enqueued_jobs only: [ TelegramAgentTriggerJob, TelegramGroupNoticeJob ] do
      assert_no_difference "TelegramMessage.count" do
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end
    assert_not group.reload.allowed?
  end

  test "three bot wakes are admitted and later addressed bot messages become context with one notice" do
    group = allowed_group
    group.update!(answers_bots: true)
    3.times { |index| ProcessTelegramUpdateJob.perform_now(@agent, bot_message(101 + index)) }
    assert_nil group.reload.bot_cap_notice_message_id
    fourth = bot_message(104)

    notice_args = ->(args) { args == [ group, { bot_cap_message_id: group.reload.bot_cap_notice_message_id } ] }
    assert_enqueued_with(job: TelegramGroupNoticeJob, args: notice_args) do
      assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
        ProcessTelegramUpdateJob.perform_now(@agent, fourth)
      end
    end
    assert_equal group.telegram_messages.find_by!(telegram_message_id: 104).id, group.reload.bot_cap_notice_message_id
    assert_equal 3, group.bot_wake_streak
    assert_no_enqueued_jobs only: [ TelegramAgentTriggerJob, TelegramGroupNoticeJob ] do
      ProcessTelegramUpdateJob.perform_now(@agent, fourth.deep_dup)
      ProcessTelegramUpdateJob.perform_now(@agent, bot_message(105))
    end
    assert_equal [ true, true, true, false, false ], group.telegram_messages.order(:id).map(&:addressed?)
    assert_equal 3, enqueued_jobs.count { |job| job["job_class"] == "TelegramAgentTriggerJob" }
  end

  test "an unaddressed human message resets the cap and permits a new streak and notice" do
    group = allowed_group
    group.update!(answers_bots: true)
    4.times { |index| ProcessTelegramUpdateJob.perform_now(@agent, bot_message(101 + index)) }
    first_notice_id = group.reload.bot_cap_notice_message_id
    human = group_message("a person is here")
    human["message"]["message_id"] = 200

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      ProcessTelegramUpdateJob.perform_now(@agent, human)
    end
    assert_equal 0, group.reload.bot_wake_streak
    assert_nil group.bot_cap_notice_message_id
    3.times { |index| ProcessTelegramUpdateJob.perform_now(@agent, bot_message(201 + index)) }
    notice_args = ->(args) { args == [ group, { bot_cap_message_id: group.reload.bot_cap_notice_message_id } ] }
    assert_enqueued_with(job: TelegramGroupNoticeJob, args: notice_args) do
      ProcessTelegramUpdateJob.perform_now(@agent, bot_message(204))
    end
    assert_equal 3, group.reload.bot_wake_streak
    assert_equal group.telegram_messages.find_by!(telegram_message_id: 204).id, group.bot_cap_notice_message_id
    assert_not_equal first_notice_id, group.bot_cap_notice_message_id
  end

  test "duplicate bot and human updates neither spend nor reset another streak" do
    group = allowed_group
    group.update!(answers_bots: true)
    human = group_message("hello")
    ProcessTelegramUpdateJob.perform_now(@agent, human)
    bot = bot_message(101)
    ProcessTelegramUpdateJob.perform_now(@agent, bot)

    assert_no_enqueued_jobs only: [ TelegramAgentTriggerJob, TelegramGroupNoticeJob ] do
      ProcessTelegramUpdateJob.perform_now(@agent, bot.deep_dup)
      ProcessTelegramUpdateJob.perform_now(@agent, human.deep_dup)
    end
    assert_equal 1, group.reload.bot_wake_streak
    assert_equal 2, group.telegram_messages.count
  end

  test "an unsupported human message resets once without waking even when replying to the bot" do
    group = allowed_group
    group.update!(answers_bots: true, bot_wake_streak: 3, bot_cap_notice_message_id: 42)
    human = group_message(nil, [], reply_to: { "from" => { "id" => 4242 } })
    human["message"]["sticker"] = { "file_id" => "sticker" }

    assert_no_enqueued_jobs only: [ TelegramAgentTriggerJob, PrepareTelegramMediaJob ] do
      ProcessTelegramUpdateJob.perform_now(@agent, human)
    end
    assert_equal 0, group.reload.bot_wake_streak
    assert_nil group.bot_cap_notice_message_id
    placeholder = group.telegram_messages.sole
    assert_equal "[Unsupported Telegram message]", placeholder.text
    assert_not placeholder.addressed?

    ProcessTelegramUpdateJob.perform_now(@agent, bot_message(101))
    assert_no_difference "TelegramMessage.count" do
      ProcessTelegramUpdateJob.perform_now(@agent, human.deep_dup)
    end
    assert_equal 1, group.reload.bot_wake_streak
  end

  test "unavailable residents do not spend bot text wake slots" do
    group = allowed_group
    group.update!(answers_bots: true)
    [
      [ :active?, false ],
      [ :paused?, true ],
      [ :billing_held?, true ],
      [ :external?, false ],
      [ :trigger_bearer_token, nil ]
    ].each_with_index do |(method, value), index|
      @agent.stub method, value do
        assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
          ProcessTelegramUpdateJob.perform_now(@agent, bot_message(101 + index))
        end
      end
    end
    assert_equal 0, group.reload.bot_wake_streak
    assert_equal 5, group.telegram_messages.count
    assert group.telegram_messages.none?(&:addressed?)
  end

  test "bot media reserves a slot and capped media follows the context path" do
    group = allowed_group
    group.update!(answers_bots: true, bot_wake_streak: 2)
    update = bot_photo(101)
    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    assert group.telegram_messages.sole.addressed?
    assert_equal 3, group.reload.bot_wake_streak

    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
        ProcessTelegramUpdateJob.perform_now(@agent, bot_photo(102))
      end
    end
    assert_not group.telegram_messages.order(:id).last.addressed?
    assert_equal 3, group.reload.bot_wake_streak
    assert_no_enqueued_jobs only: [ PrepareTelegramMediaJob, TelegramGroupNoticeJob ] do
      ProcessTelegramUpdateJob.perform_now(@agent, update.deep_dup)
    end
  end

  test "bot media with answers off is context and oversized suppressed media gets no error reply" do
    group = allowed_group
    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, bot_photo(101))
    end
    assert_not group.telegram_messages.sole.addressed?
    group.update!(answers_bots: true, bot_wake_streak: 3, bot_cap_notice_message_id: 42)
    oversized = bot_photo(102)
    oversized["message"]["photo"].first["file_size"] = 500.megabytes

    Net::HTTP.stub :post, ->(*) { flunk "nothing may be sent for suppressed oversized media" } do
      assert_no_enqueued_jobs only: [ PrepareTelegramMediaJob, TelegramAgentTriggerJob ] do
        ProcessTelegramUpdateJob.perform_now(@agent, oversized)
      end
    end
    message = group.telegram_messages.order(:id).last
    assert_not message.addressed?
    assert_equal "failed", message.media_status
  end

  test "in a group that is on, a person writing the resident's name wakes it like a mention" do
    group = allowed_group
    [ "Group Agent?", "what do you think, group agent", "(Group Agent) look at this" ].each_with_index do |text, index|
      update = group_message(text)
      update["message"]["message_id"] = 300 + index
      assert_enqueued_with(job: TelegramAgentTriggerJob) do
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end
    assert group.telegram_messages.all?(&:addressed?)
  end

  test "the name only counts as a whole word, and never from another bot" do
    group = allowed_group
    by_bot = group_message("Group Agent is still silent")
    by_bot["message"]["from"]["is_bot"] = true
    cases = [ group_message("the Group Agents meeting"), group_message("MyGroup Agent"), by_bot ]

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      cases.each_with_index do |update, index|
        update["message"]["message_id"] = 400 + index
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end
    assert_equal 3, group.telegram_messages.count
    assert group.telegram_messages.none?(&:addressed?)
  end

  test "an owner writing the resident's name does not switch a group on" do
    link_owner_telegram
    assert_no_difference "TelegramMessage.count" do
      ProcessTelegramUpdateJob.perform_now(@agent, group_message("Group Agent, are you there?"))
    end
    assert_not @agent.telegram_groups.sole.allowed?
  end

  test "a name in a media caption counts too" do
    group = allowed_group
    update = group_message(nil)
    update["message"].delete("text")
    update["message"]["caption"] = "group agent what is this?"
    update["message"]["photo"] = [ { "file_id" => "p1", "file_unique_id" => "u1", "width" => 10, "height" => 10, "file_size" => 100 } ]

    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end
    assert group.telegram_messages.sole.addressed?
  end

  test "a name under three characters does not count" do
    @agent.update!(name: "Al")
    group = allowed_group

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      ProcessTelegramUpdateJob.perform_now(@agent, group_message("Al, are you there?"))
    end
    assert_not group.telegram_messages.sole.addressed?
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

  def bot_message(id, text = "@group_bot ping", entities = nil, reply_to: nil)
    entities ||= text.include?("@group_bot") ? mention_entity(text) : []
    update = group_message(text, entities, reply_to: reply_to)
    update["message"]["message_id"] = id
    update["message"]["from"] = { "id" => 888, "is_bot" => true, "first_name" => "Other bot", "username" => "other_bot" }
    update
  end

  def bot_photo(id)
    update = bot_message(id)
    update["message"]["caption"] = update["message"].delete("text")
    update["message"]["caption_entities"] = update["message"].delete("entities")
    update["message"]["photo"] = [ { "file_id" => "p1", "width" => 10, "height" => 10, "file_size" => 100 } ]
    update
  end

  # Ana (Telegram id 77) is user_1, an owner, with her Telegram linked to the bot.
  def link_owner_telegram
    @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 77)
  end

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
