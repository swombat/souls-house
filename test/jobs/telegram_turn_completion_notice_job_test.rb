require "test_helper"
require "webmock/minitest"

class TelegramTurnCompletionNoticeJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(telegram_bot_token: "123:TEST", telegram_bot_username: "test_bot")
    @subscription = @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 111)
    @run = @agent.agent_runtime_interactions.create!(
      trigger_kind: "telegram", run_id: SecureRandom.uuid, started_at: Time.current,
      conversation_obfuscated_id: @subscription.to_param, provider_auth_mode: "api_key"
    )
    @send = stub_request(:post, "https://api.telegram.org/bot123:TEST/sendMessage")
      .to_return(body: { ok: true, result: { message_id: 99 } }.to_json)
  end

  test "only a finished successful Telegram turn enqueues and duplicate jobs send once" do
    TelegramTurnCompletionNoticeJob.perform_now(@run.id)
    assert_not_requested @send
    assert_enqueued_with(job: TelegramTurnCompletionNoticeJob, args: [ @run.id ]) do
      @run.record_result!(status: 200, body: { "status" => "ok", "telegram_delivery_run_id" => @run.run_id })
    end
    2.times { TelegramTurnCompletionNoticeJob.perform_now(@run.id) }
    assert_requested @send, times: 1
    assert @run.reload.telegram_completion_notice_at
  end

  test "a deleted or blocked thread or deleted run is harmless" do
    @run.record_result!(status: 200, body: { "status" => "ok", "telegram_delivery_run_id" => @run.run_id })
    @subscription.mark_blocked!
    TelegramTurnCompletionNoticeJob.perform_now(@run.id)
    @subscription.destroy!
    TelegramTurnCompletionNoticeJob.perform_now(@run.id)
    @run.destroy!
    TelegramTurnCompletionNoticeJob.perform_now(@run.id)
    assert_not_requested @send
  end

  test "failed results enqueue no success notice" do
    assert_no_enqueued_jobs(only: TelegramTurnCompletionNoticeJob) do
      @run.record_result!(status: 500, body: { "status" => "error" })
    end
  end

  test "notice queue failure does not rewrite a successful runtime result" do
    TelegramTurnCompletionNoticeJob.stub(:perform_later, ->(*) { raise "synthetic queue failure" }) do
      @run.record_result!(status: 200, body: { "status" => "ok", "telegram_delivery_run_id" => @run.run_id })
    end
    assert_equal "ok", @run.reload.runtime_status
    assert @run.finished_at
  end

end
