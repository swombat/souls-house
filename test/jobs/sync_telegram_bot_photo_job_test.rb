require "test_helper"
require "ostruct"
require "webmock/minitest"

class SyncTelegramBotPhotoJobTest < ActiveJob::TestCase

  BASE = "https://api.telegram.org/bot123:ABC".freeze

  setup do
    @agent = agents(:research_assistant)
    # update_columns: no webhook job, so the only requests are the ones under test.
    @agent.update_columns(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    @agent.reload
    assert_equal "123:ABC", @agent.telegram_bot_token
  end

  test "a resident's picture becomes the bot's profile photo, sent as a JPEG" do
    attach_png
    captured = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      parts = request.instance_variable_get(:@body_data)
      upload = parts.find { |part| part.first == "profile_photo" }
      captured = { path: request.path, photo: parts.find { |part| part.first == "photo" }&.second,
                   bytes: upload.second.read, options: upload.third }
      OpenStruct.new(body: { ok: true, result: true }.to_json)
    end

    Net::HTTP.stub :start, ->(*_args, **_options, &block) { block.call(http) } do
      SyncTelegramBotPhotoJob.perform_now(@agent)
    end

    assert_equal "/bot123:ABC/setMyProfilePhoto", captured[:path]
    assert_equal({ "type" => "static", "photo" => "attach://profile_photo" }, JSON.parse(captured[:photo]))
    assert_equal({ filename: "profile.jpg", content_type: "image/jpeg" }, captured[:options])
    assert captured[:bytes].b.start_with?("\xFF\xD8\xFF".b), "the upload is a JPEG, converted from the PNG"
  end

  test "no picture here removes the bot's photo" do
    stub_request(:post, "#{BASE}/removeMyProfilePhoto").to_return(body: { ok: true, result: true }.to_json)

    SyncTelegramBotPhotoJob.perform_now(@agent)

    assert_requested :post, "#{BASE}/removeMyProfilePhoto", times: 1
  end

  test "linking a bot to a resident without a picture leaves the bot's own photo alone" do
    SyncTelegramBotPhotoJob.perform_now(@agent, remove_when_missing: false)

    assert_not_requested :any, /api\.telegram\.org/
  end

  test "a resident without a bot makes no request" do
    @agent.update_columns(telegram_bot_token: nil, telegram_bot_username: nil)
    attach_png

    SyncTelegramBotPhotoJob.perform_now(@agent)

    assert_not_requested :any, /api\.telegram\.org/
  end

  test "a refusal from Telegram is logged, not retried" do
    attach_png
    stub_request(:post, "#{BASE}/setMyProfilePhoto")
      .to_return(body: { ok: false, error_code: 401, description: "Unauthorized" }.to_json)

    assert_no_enqueued_jobs(only: SyncTelegramBotPhotoJob) do
      assert_nothing_raised { SyncTelegramBotPhotoJob.perform_now(@agent) }
    end
  end

  test "one sync at a time per resident, so an older upload can't finish after a newer one" do
    other = agents(:code_reviewer)

    assert_equal 1, SyncTelegramBotPhotoJob.concurrency_limit
    assert_equal SyncTelegramBotPhotoJob.new(@agent).concurrency_key,
      SyncTelegramBotPhotoJob.new(@agent, remove_when_missing: false).concurrency_key
    assert_not_equal SyncTelegramBotPhotoJob.new(@agent).concurrency_key, SyncTelegramBotPhotoJob.new(other).concurrency_key
  end

  test "a job queued for a picture that was removed before it ran removes the bot's photo" do
    attach_png
    job = SyncTelegramBotPhotoJob.new(@agent)
    @agent.retire_avatar!
    stub_request(:post, "#{BASE}/removeMyProfilePhoto").to_return(body: { ok: true, result: true }.to_json)

    job.perform_now

    assert_requested :post, "#{BASE}/removeMyProfilePhoto", times: 1
    assert_not_requested :post, "#{BASE}/setMyProfilePhoto"
  end

  test "flood control is retried after the wait Telegram asks for" do
    freeze_time
    stub_request(:post, "#{BASE}/removeMyProfilePhoto")
      .to_return(body: { ok: false, error_code: 429, description: "Too Many Requests: retry after 7",
                         parameters: { retry_after: 7 } }.to_json)

    assert_enqueued_with(job: SyncTelegramBotPhotoJob, args: [ @agent ], at: 8.seconds.from_now) do
      SyncTelegramBotPhotoJob.perform_now(@agent)
    end
  end

  test "Telegram's own trouble is retried, an HTML error page included" do
    stub_request(:post, "#{BASE}/removeMyProfilePhoto")
      .to_return(body: { ok: false, error_code: 503, description: "Service Unavailable" }.to_json)
    assert_enqueued_with(job: SyncTelegramBotPhotoJob) { SyncTelegramBotPhotoJob.perform_now(@agent) }

    clear_enqueued_jobs
    stub_request(:post, "#{BASE}/removeMyProfilePhoto").to_return(status: 502, body: "<html>Bad Gateway</html>")
    assert_enqueued_with(job: SyncTelegramBotPhotoJob) { SyncTelegramBotPhotoJob.perform_now(@agent) }
  end

  test "flood control stops being retried after the last attempt" do
    stub_request(:post, "#{BASE}/removeMyProfilePhoto")
      .to_return(body: { ok: false, error_code: 429, description: "Too Many Requests", parameters: { retry_after: 3 } }.to_json)
    job = SyncTelegramBotPhotoJob.new(@agent)
    job.executions = SyncTelegramBotPhotoJob::ATTEMPTS - 1

    assert_no_enqueued_jobs(only: SyncTelegramBotPhotoJob) do
      assert_nothing_raised { job.perform_now }
    end
  end

  private

  def attach_png
    @agent.avatar.attach(io: file_fixture("test_avatar.png").open, filename: "a.png", content_type: "image/png")
  end

end
