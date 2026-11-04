require "test_helper"

class TelegramSubscriptionTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = @account.agents.create!(name: "Sub Agent")
    @user = users(:user_1)
  end

  test "creates valid subscription" do
    sub = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 12345)
    assert sub.persisted?
  end

  test "enforces uniqueness on agent_id and user_id" do
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 111)
    duplicate = @agent.telegram_subscriptions.build(user: @user, telegram_chat_id: 222)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
  end

  test "enforces uniqueness on agent_id and telegram_chat_id" do
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 111)
    other_user = users(:existing_user)
    duplicate = @agent.telegram_subscriptions.build(user: other_user, telegram_chat_id: 111)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
  end

  test "active scope excludes blocked subscriptions" do
    active = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 111)
    blocked = @agent.telegram_subscriptions.create!(user: users(:existing_user), telegram_chat_id: 222, blocked: true)

    results = @agent.telegram_subscriptions.active
    assert_includes results, active
    assert_not_includes results, blocked
  end

  test "mark_blocked! sets blocked flag" do
    sub = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 111)
    sub.mark_blocked!
    assert sub.reload.blocked?
  end

  test "uses a stable obfuscated thread id" do
    sub = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 111)

    assert_equal sub, TelegramSubscription.find(sub.to_param)
    assert_not_equal sub.id.to_s, sub.to_param
  end

  test "bot answers default off with any username permitted when enabled" do
    group = @agent.telegram_groups.create!(telegram_chat_id: -123)
    assert_not group.answers_bots?
    assert_equal [], group.answer_bot_usernames
    assert_equal 0, group.bot_wake_streak
    assert_nil group.bot_cap_notice_message_id
    assert_not group.answers_bot?("other_bot")

    group.update!(answers_bots: true, answer_bot_usernames: [ "", "  " ])
    assert group.answers_bot?("other_bot")
    assert group.answers_bot?(nil), "an empty list admits even bots without a username"
  end

  test "bot username list is normalized and limits which bots can wake" do
    group = @agent.telegram_groups.create!(
      telegram_chat_id: -123, answers_bots: true,
      answer_bot_usernames: [ " @Other_Bot ", "OTHER_BOT", "", "Second_bot" ]
    )

    assert_equal %w[other_bot second_bot], group.reload.answer_bot_usernames
    assert group.answers_bot?("Other_Bot")
    assert_not group.answers_bot?("unlisted_bot")
    assert_not group.answers_bot?(nil)
    group.update!(answers_bots: false)
    assert_not group.answers_bot?("other_bot")
  end

  test "bot username list rejects malformed Telegram usernames" do
    group = @agent.telegram_groups.build(telegram_chat_id: -123)
    [ "@", "tiny", "1other_bot", "other-bot", "two bots", "@@other_bot", "éther_bot", "a" * 33 ].each do |username|
      group.answer_bot_usernames = [ username ]
      assert_not group.valid?, username
      assert group.errors[:answer_bot_usernames].any?, username
    end
  end

  test "bot streak cannot exceed the cap or be negative" do
    group = @agent.telegram_groups.build(telegram_chat_id: -123)
    [ -1, 4 ].each do |streak|
      group.bot_wake_streak = streak
      assert_not group.valid?
      assert group.errors[:bot_wake_streak].any?
    end
  end

end
