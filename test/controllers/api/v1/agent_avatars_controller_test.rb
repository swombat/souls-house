require "test_helper"

class Api::V1::AgentAvatarsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @resident_key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    @owner_key = ApiKey.generate_for(@agent.account.owner, name: "owner")
  end

  test "a resident uploads its own picture, audited as the resident" do
    patch "/api/v1/agent/avatar", params: { avatar: fixture_file_upload("test_avatar.png", "image/png") },
      headers: auth(@resident_key)

    assert_response :success
    @agent.reload
    assert @agent.avatar.attached?
    assert_equal @agent.avatar_url, response.parsed_body["avatar_url"]
    log = AuditLog.find_by!(action: "set_agent_avatar", auditable: @agent)
    assert_nil log.user
    assert_equal @agent.id, log.data["agent_id"]
    assert_equal @resident_key.id, log.data["api_key_id"]
  end

  test "a resident gives a web address and the house fetches it" do
    image = RemoteImageFetch::Result.new(io: StringIO.new(file_fixture("test_avatar.png").binread), filename: "x.png", content_type: "image/png")
    RemoteImageFetch.stub(:call, ->(url) { assert_equal "https://pics.example/x.png", url; image }) do
      patch "/api/v1/agent/avatar", params: { url: "https://pics.example/x.png" }, as: :json, headers: auth(@resident_key)
    end

    assert_response :success
    assert @agent.reload.avatar.attached?
  end

  test "a refused fetch, a string in place of a file, and nothing at all are errors that change nothing" do
    RemoteImageFetch.stub(:call, ->(_) { raise RemoteImageFetch::Error, "That address isn't on the public internet" }) do
      patch "/api/v1/agent/avatar", params: { url: "http://169.254.169.254/x" }, as: :json, headers: auth(@resident_key)
    end
    assert_response :unprocessable_entity
    assert_equal [ "That address isn't on the public internet" ], response.parsed_body["errors"]

    patch "/api/v1/agent/avatar", params: { avatar: "some-signed-blob-id" }, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity

    patch "/api/v1/agent/avatar", params: {}, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity

    assert_not @agent.reload.avatar.attached?
    assert_not AuditLog.exists?(action: "set_agent_avatar", auditable: @agent)
  end

  test "a resident removes its own picture" do
    @agent.avatar.attach(io: file_fixture("test_avatar.png").open, filename: "a.png", content_type: "image/png")

    delete "/api/v1/agent/avatar", headers: auth(@resident_key)

    assert_response :success
    assert_nil response.parsed_body["avatar_url"]
    assert_not @agent.reload.avatar.attached?
    assert AuditLog.exists?(action: "remove_agent_avatar", auditable: @agent)
  end

  test "a person's key is refused: owners use the Appearance tab" do
    patch "/api/v1/agent/avatar", params: { avatar: fixture_file_upload("test_avatar.png", "image/png") },
      headers: auth(@owner_key)
    assert_response :forbidden
    delete "/api/v1/agent/avatar", headers: auth(@owner_key)
    assert_response :forbidden
    assert_not @agent.reload.avatar.attached?
  end

  test "with a Telegram bot linked, setting and removing the picture send the bot after it" do
    @agent.update_columns(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")

    assert_enqueued_with(job: SyncTelegramBotPhotoJob, args: [ @agent ]) do
      patch "/api/v1/agent/avatar", params: { avatar: fixture_file_upload("test_avatar.png", "image/png") },
        headers: auth(@resident_key)
    end
    assert_enqueued_with(job: SyncTelegramBotPhotoJob, args: [ @agent ]) do
      delete "/api/v1/agent/avatar", headers: auth(@resident_key)
    end
  end

  test "without a bot, and on a refused change, nothing is sent to Telegram" do
    assert_no_enqueued_jobs(only: SyncTelegramBotPhotoJob) do
      patch "/api/v1/agent/avatar", params: { avatar: fixture_file_upload("test_avatar.png", "image/png") },
        headers: auth(@resident_key)
    end

    @agent.update_columns(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    assert_no_enqueued_jobs(only: SyncTelegramBotPhotoJob) do
      patch "/api/v1/agent/avatar", params: {}, as: :json, headers: auth(@resident_key)
    end
  end

  private

  def auth(key)
    { Authorization: "Bearer #{key.raw_token}" }
  end

end
