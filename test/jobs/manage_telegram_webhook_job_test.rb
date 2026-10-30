require "test_helper"
require "webmock/minitest"

class ManageTelegramWebhookJobTest < ActiveJob::TestCase

  setup do
    @previous_public_url = Rails.configuration.x.public_url
    Rails.configuration.x.public_url = "https://house.example.test"
    @agent = agents(:research_assistant)
    @agent.update_columns(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot123:ABC/(setWebhook|getMe)\z})
      .to_return(body: { ok: true, result: {} }.to_json)
  end

  teardown { Rails.configuration.x.public_url = @previous_public_url }

  test "linking a bot to a resident with a picture sends the picture, never a removal" do
    @agent.avatar.attach(io: file_fixture("test_avatar.png").open, filename: "a.png", content_type: "image/png")

    assert_enqueued_with(job: SyncTelegramBotPhotoJob, args: [ @agent, { remove_when_missing: false } ]) do
      ManageTelegramWebhookJob.perform_now(@agent)
    end
  end

  test "linking a bot to a resident without a picture leaves the bot's photo alone" do
    assert_no_enqueued_jobs(only: SyncTelegramBotPhotoJob) do
      ManageTelegramWebhookJob.perform_now(@agent)
    end
  end

end
