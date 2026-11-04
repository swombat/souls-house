require "test_helper"
require "ostruct"

class TelegramGroupNoticeJobTest < ActiveSupport::TestCase

  setup do
    fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub :post, fake_ok do
      accounts(:personal_account).agents.create!(
        name: "A < B & C", telegram_bot_token: "4242:ABC", telegram_bot_username: "notice_bot"
      )
    end
    @group = @agent.telegram_groups.create!(telegram_chat_id: -100_555, title: "Group")
    @group.allow!(by: users(:user_1))
  end

  test "normal group notice explains bot waking, owner allowance and cap only when enabled" do
    text = TelegramGroupNoticeJob.text_for(@group)
    assert_not_includes text, "Other bots can also wake"

    @group.update!(answers_bots: true)
    text = TelegramGroupNoticeJob.text_for(@group)
    assert_includes text, "Other bots can also wake"
    assert_includes text, "owner's account allowance"
    assert_includes text, "3 times in a row"
    assert_includes text, "a message from a person"
    assert_includes text, "Any bot, with or without a username, is allowed."
  end

  test "group notice names the permitted bot usernames when the list is restricted" do
    @group.update!(answers_bots: true, answer_bot_usernames: [ "@Other_Bot", "SECOND_BOT" ])
    text = TelegramGroupNoticeJob.text_for(@group)

    assert_includes text, "Only these bot usernames are allowed: @other_bot, @second_bot."
    assert_not_includes text, "Any bot"
  end

  test "cap notice is escaped for Telegram and kept as a house message" do
    @group.update!(answers_bots: true, bot_wake_streak: 3, bot_cap_notice_message_id: 123)
    expected = "A < B & C has answered bots 3 times in a row; a message from a person lets her continue."
    send_message = ->(chat_id, text) {
      assert_equal @group.telegram_chat_id, chat_id
      assert_equal ERB::Util.html_escape(expected), text
      { "result" => { "message_id" => 901, "date" => Time.current.to_i } }
    }
    @group.stub :agent, @agent do
      @agent.stub :telegram_send_message, send_message do
        TelegramGroupNoticeJob.perform_now(@group, bot_cap_message_id: 123)
      end
    end
    notice = @group.telegram_messages.sole
    assert_equal expected, notice.text
    assert_equal "assistant", notice.role
    assert_equal Setting.instance.site_name, notice.sender_name
    assert_equal 901, notice.telegram_message_id
  end

  test "a cap notice is not sent into a group switched off after it was queued" do
    @group.update!(answers_bots: true, bot_wake_streak: 3, bot_cap_notice_message_id: 123)
    @group.disallow!
    Net::HTTP.stub :post, ->(*) { flunk "nothing may be sent to a disabled group" } do
      assert_no_difference "TelegramMessage.count" do
        TelegramGroupNoticeJob.perform_now(@group, bot_cap_message_id: 123)
      end
    end
  end

  test "a queued cap notice reloads and skips a reset, disabled answers or a later capped streak" do
    @group.update!(answers_bots: true, bot_wake_streak: 3, bot_cap_notice_message_id: 123)
    [
      { bot_wake_streak: 0, bot_cap_notice_message_id: nil },
      { answers_bots: false },
      { bot_cap_notice_message_id: nil },
      { bot_cap_notice_message_id: 124 }
    ].each do |changes|
      @group.update!(answers_bots: true, bot_wake_streak: 3, bot_cap_notice_message_id: 123)
      TelegramSubscription.find(@group.id).update!(changes)
      Net::HTTP.stub :post, ->(*) { flunk "a stale cap notice must not be sent" } do
        assert_no_difference "TelegramMessage.count" do
          TelegramGroupNoticeJob.perform_now(@group, bot_cap_message_id: 123)
        end
      end
    end
  end

end
