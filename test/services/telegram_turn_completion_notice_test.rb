require "test_helper"
require "webmock/minitest"

class TelegramTurnCompletionNoticeTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(telegram_bot_token: "123:TEST", telegram_bot_username: "test_bot")
    @subscription = @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 111)
    @run = make_run
    @url = "https://api.telegram.org/bot123:TEST/sendMessage"
    @send = stub_request(:post, @url).to_return(
      body: { ok: true, result: { message_id: 999 } }.to_json
    )
  end

  test "successful no-reply turn sends one house-labelled notice across repeated callbacks" do
    2.times { TelegramTurnCompletionNotice.call(@run.reload, @subscription) }
    assert_requested @send, times: 1
    assert_equal "souls.house", @subscription.telegram_messages.last.sender_name
    assert_includes @subscription.telegram_messages.last.text, "finished without sending a reply"
    assert @run.reload.telegram_completion_notice_at
    assert_empty @run.linked_telegram_messages
  end

  test "only this turn's delivered text or media suppresses a notice" do
    other_run = make_run
    @subscription.telegram_messages.create!(
      role: "assistant", text: "A neighbour's reply", sent_at: Time.current,
      telegram_message_id: 98, agent_runtime_interaction: other_run
    )
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_requested @send, times: 1
    @run = make_run
    @subscription.telegram_messages.create!(
      role: "assistant", text: "[Document]", media_kind: "document", sent_at: Time.current,
      telegram_message_id: 99, agent_runtime_interaction: @run
    )
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_requested @send, times: 1
  end

  test "undelivered stored output does not count" do
    @subscription.telegram_messages.create!(
      role: "assistant", text: "Not accepted", sent_at: Time.current, agent_runtime_interaction: @run
    )
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_requested @send
  end

  test "intentional quiet without a reason stays quiet" do
    @run.update!(quiet_reason: "", quiet_reason_at: Time.current)
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_not_requested @send
  end

  test "authored reason is carried verbatim and escaped for Telegram" do
    reason = "  Nothing <extra> to add.\nAlready answered.  "
    @run.update!(quiet_reason: reason, quiet_reason_at: Time.current)
    TelegramTurnCompletionNotice.call(@run, @subscription)
    text = @subscription.telegram_messages.last.text
    assert text.end_with?(reason)
    assert_includes text, "Their stated reason:"
    assert_requested :post, @url, body: hash_including("text" => ERB::Util.html_escape(text))
  end

  test "late completion checks its own linkage not a newer turn or elapsed time" do
    @run.update!(started_at: 2.days.ago, finished_at: 1.day.ago)
    newer = make_run
    @subscription.telegram_messages.create!(
      role: "assistant", text: "Newer answer", sent_at: Time.current,
      telegram_message_id: 12, agent_runtime_interaction: newer
    )
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_requested @send
  end

  test "unfinished failed busy or cancelled turns and groups get no success notice" do
    [
      { finished_at: nil }, { runtime_status: "error" }, { runtime_returncode: 1 },
      { transport_status: 500 }, { runtime_status: "already_running" }
    ].each do |changes|
      run = make_run
      run.update!(changes)
      TelegramTurnCompletionNotice.call(run, @subscription)
    end
    group = @agent.telegram_threads.create!(chat_kind: "group", telegram_chat_id: -123, allowed: true)
    TelegramTurnCompletionNotice.call(make_run(conversation_obfuscated_id: group.to_param), group)
    assert_not_requested @send
  end

  test "failed notice delivery is not retried by duplicate completion" do
    remove_request_stub(@send)
    @send = stub_request(:post, @url).to_return(body: { ok: false, description: "Bad Request" }.to_json)
    2.times { TelegramTurnCompletionNotice.call(@run.reload, @subscription) }
    assert_requested @send, times: 1
    assert_empty @subscription.telegram_messages
    assert @run.reload.telegram_completion_notice_at
  end

  test "an ambiguous network failure is not blindly retried" do
    remove_request_stub(@send)
    @send = stub_request(:post, @url).to_timeout
    2.times { TelegramTurnCompletionNotice.call(@run.reload, @subscription) }
    assert_requested @send, times: 1
    assert @run.reload.telegram_completion_notice_at
    assert_equal "ok", @run.runtime_status
  end

  test "a blocked subscriber gets no notice" do
    @subscription.mark_blocked!
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_not_requested @send
  end

  test "older runtimes without delivery accounting do not falsely report a missing reply" do
    @run.update!(response_body: {})
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_not_requested @send
  end

  test "diagnostic stdout is never a delivery receipt" do
    @run.update!(stdout: "Here is my final answer.")
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_requested @send
  end

  test "a receipt storage error does not roll back the attempt or poison completion" do
    @subscription.telegram_messages.create!(
      role: "assistant", text: "Existing receipt", telegram_message_id: 999, sent_at: Time.current
    )
    @run.with_lock do
      TelegramTurnCompletionNotice.call(@run, @subscription)
      @run.update!(duration_ms: 123)
    end
    assert_equal 123, @run.reload.duration_ms
    assert @run.telegram_completion_notice_at
    TelegramTurnCompletionNotice.call(@run, @subscription)
    assert_requested @send, times: 1
  end

  private

  def make_run(**attributes)
    run_id = SecureRandom.uuid
    @agent.agent_runtime_interactions.create!({
      trigger_kind: "telegram", conversation_obfuscated_id: @subscription.to_param,
      session_id: "#{@agent.uuid}-telegram-#{@subscription.id}", run_id: run_id,
      started_at: Time.current, finished_at: Time.current, runtime_status: "ok",
      transport_status: 200, provider_auth_mode: "api_key",
      response_body: { "telegram_delivery_run_id" => run_id }
    }.merge(attributes))
  end

end
