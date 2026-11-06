require "test_helper"
require "ostruct"

class ProcessTelegramUpdateJobTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub :post, @fake_ok do
      @account.agents.create!(
        name: "Update Agent",
        telegram_bot_token: "123:ABC",
        telegram_bot_username: "update_bot"
      )
    end
    # Use memory store so deep link tokens persist within the test
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "creates subscription on /start with valid deep link" do
    token = "test_token_#{SecureRandom.hex(8)}"
    Rails.cache.write("telegram_deep_link:#{token}", { user_id: @user.id, agent_id: @agent.id }, expires_in: 7.days)

    Net::HTTP.stub :post, @fake_ok do
      assert_difference "TelegramSubscription.count", 1 do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("/start #{token}"))
      end
    end

    sub = @agent.telegram_subscriptions.last
    assert_equal @user, sub.user
    assert_equal 456, sub.telegram_chat_id
    assert_not sub.blocked?
    assert_equal 0, @agent.reload.telegram_unlinked_messages_count
    assert_nil @agent.telegram_unlinked_last_received_at
  end

  test "updates existing subscription and unblocks" do
    sub = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 999, blocked: true)
    token = "test_token_#{SecureRandom.hex(8)}"
    Rails.cache.write("telegram_deep_link:#{token}", { user_id: @user.id, agent_id: @agent.id }, expires_in: 7.days)

    Net::HTTP.stub :post, @fake_ok do
      assert_no_difference "TelegramSubscription.count" do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("/start #{token}"))
      end
    end

    sub.reload
    assert_equal 456, sub.telegram_chat_id
    assert_not sub.blocked?
  end

  test "sends error message for missing deep link param" do
    Net::HTTP.stub :post, @fake_ok do
      assert_no_difference "TelegramSubscription.count" do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("/start"))
      end
    end
  end

  test "sends error for expired deep link" do
    token = "test_token_#{SecureRandom.hex(8)}"
    Rails.cache.write("telegram_deep_link:#{token}", { user_id: @user.id, agent_id: @agent.id }, expires_in: 0.seconds)
    sleep 0.1

    Net::HTTP.stub :post, @fake_ok do
      assert_no_difference "TelegramSubscription.count" do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("/start #{token}"))
      end
    end
  end

  test "rejects cross-account user" do
    # regular_user only belongs to regular_user_account, NOT personal_account
    cross_user = users(:regular_user)
    token = "test_token_#{SecureRandom.hex(8)}"
    Rails.cache.write("telegram_deep_link:#{token}", { user_id: cross_user.id, agent_id: @agent.id }, expires_in: 7.days)

    Net::HTTP.stub :post, @fake_ok do
      assert_no_difference "TelegramSubscription.count" do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("/start #{token}"))
      end
    end
  end

  test "unlinked arrivals receive instructions and retain only agent aggregates" do
    @agent.update!(runtime: "external", endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    sent = []
    responder = lambda do |_uri, body, _headers|
      sent << JSON.parse(body)
      @fake_ok
    end

    freeze_time do
      assert_no_difference [ "TelegramSubscription.count", "TelegramMessage.count", "AgentRuntimeInteraction.count", "ActiveStorage::Attachment.count" ] do
        assert_no_enqueued_jobs do
          Net::HTTP.stub :post, responder do
            ProcessTelegramUpdateJob.perform_now(@agent, build_update("private inbound text", username: "private_username"))
            ProcessTelegramUpdateJob.perform_now(@agent, build_media_update("photo" => [ { "file_id" => "private-file" } ], "caption" => "private caption"))
          end
        end
      end

      assert_equal 2, @agent.reload.telegram_unlinked_messages_count
      assert_equal Time.current, @agent.telegram_unlinked_last_received_at
    end
    assert_equal 1, sent.size
    assert_equal 456, sent.first.fetch("chat_id")
    assert_includes sent.first.fetch("text"), "registration link"
    assert_includes sent.first.fetch("text"), "wasn't delivered"
    refute_includes sent.to_json, "private inbound text"
    refute_includes sent.to_json, "private_username"
    refute_includes sent.to_json, "private caption"
  end

  test "unlinked instructions expire after 24 hours without extending the throttle" do
    sent = []
    responder = ->(*args) { sent << args; @fake_ok }

    freeze_time do
      Net::HTTP.stub :post, responder do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("first"))
        travel 23.hours
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("second"))
        assert_equal 1, sent.size
        travel 1.hour + 1.second
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("third"))
        assert_equal 2, sent.size
      end
      assert_equal 3, @agent.reload.telegram_unlinked_messages_count
      assert_equal Time.current, @agent.telegram_unlinked_last_received_at
    end
  end

  test "unlinked instructions have independent agent and chat throttles" do
    other_agent = @account.agents.create!(name: "Other Agent")
    sent = []
    responder = ->(*args) { sent << args; @fake_ok }
    other_chat = build_update("other chat")
    other_chat["message"]["chat"]["id"] = 987654321

    Net::HTTP.stub :post, responder do
      ProcessTelegramUpdateJob.perform_now(@agent, build_update("first"))
      ProcessTelegramUpdateJob.perform_now(@agent, other_chat)
      ProcessTelegramUpdateJob.perform_now(other_agent, build_update("other agent"))
      ProcessTelegramUpdateJob.perform_now(@agent, other_chat)
    end
    assert_equal 3, sent.size
    assert_equal 3, @agent.reload.telegram_unlinked_messages_count
    assert_equal 1, other_agent.reload.telegram_unlinked_messages_count
  end

  test "unlinked throttle atomically writes only a hashed chat key and boolean" do
    cache = Minitest::Mock.new
    cache_key = "telegram_unlinked_instructions:#{@agent.id}:#{Digest::SHA256.hexdigest('456')}"
    cache.expect :write, false, [ cache_key, true ], unless_exist: true, expires_in: 24.hours

    Rails.stub :cache, cache do
      @agent.stub :telegram_send_message, ->(*) { flunk "Throttled instructions must not be sent" } do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("secret", username: "secret_username"))
      end
    end
    cache.verify
    assert_equal 1, @agent.reload.telegram_unlinked_messages_count
  end

  test "unlinked aggregates increment from database state and never move latest time backwards" do
    freeze_time do
      latest = 1.hour.from_now
      Agent.where(id: @agent.id).update_all(telegram_unlinked_messages_count: 40, telegram_unlinked_last_received_at: latest)

      Net::HTTP.stub :post, @fake_ok do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("hello"))
      end
      assert_equal 41, @agent.reload.telegram_unlinked_messages_count
      assert_equal latest, @agent.telegram_unlinked_last_received_at
    end
  end

  test "valid start still links a chat while unlinked instructions are throttled" do
    token = "test_token_#{SecureRandom.hex(8)}"
    Rails.cache.write("telegram_deep_link:#{token}", { user_id: @user.id, agent_id: @agent.id }, expires_in: 7.days)

    Net::HTTP.stub :post, @fake_ok do
      ProcessTelegramUpdateJob.perform_now(@agent, build_update("hello"))
      assert_difference "TelegramSubscription.count", 1 do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("/start #{token}"))
      end
    end
    assert_equal 456, @agent.telegram_subscriptions.last.telegram_chat_id
    assert_equal 1, @agent.reload.telegram_unlinked_messages_count
  end

  test "unlinked reset unsupported content and invalid start are counted and receive instructions" do
    updates = [
      build_update("/reset"),
      build_media_update("document" => { "file_id" => "doc" }),
      build_media_update("sticker" => { "file_id" => "sticker" }),
      build_update("/start invalid")
    ]
    sent = []
    responder = ->(*args) { sent << args; @fake_ok }

    assert_no_difference [ "TelegramSubscription.count", "TelegramMessage.count", "AgentRuntimeInteraction.count" ] do
      assert_no_enqueued_jobs do
        Net::HTTP.stub :post, responder do
          updates.each_with_index do |update, index|
            update["message"]["chat"]["id"] = 1000 + index
            ProcessTelegramUpdateJob.perform_now(@agent, update)
          end
        end
      end
    end
    assert_equal 4, sent.size
    assert_equal 4, @agent.reload.telegram_unlinked_messages_count
  end

  test "unlinked instructions escape the agent name for Telegram HTML" do
    @agent.update!(name: "A <b>name</b> & friend")
    sent = []
    responder = ->(_uri, body, _headers) { sent << JSON.parse(body); @fake_ok }

    Net::HTTP.stub :post, responder do
      ProcessTelegramUpdateJob.perform_now(@agent, build_update("hello"))
    end
    assert_equal "HTML", sent.first.fetch("parse_mode")
    assert_includes sent.first.fetch("text"), "<b>A &lt;b&gt;name&lt;/b&gt; &amp; friend</b>"
    refute_includes sent.first.fetch("text"), "<b>name</b>"
  end

  test "failed unlinked replies still leave owner aggregates and remain throttled" do
    calls = 0
    responder = lambda do |*|
      calls += 1
      raise TelegramNotifiable::TelegramError, "Forbidden"
    end

    freeze_time do
      Net::HTTP.stub :post, responder do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("hello"))
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("again"))
      end
      assert_equal 2, @agent.reload.telegram_unlinked_messages_count
      assert_equal Time.current, @agent.telegram_unlinked_last_received_at
    end
    assert_equal 1, calls
  end

  test "group messages do not receive unlinked DM instructions or affect aggregates" do
    %w[group supergroup channel].each do |chat_type|
      update = build_update("hello")
      update["message"]["chat"] = { "id" => -456, "type" => chat_type, "title" => "Group" }

      @agent.stub :telegram_send_message, ->(*) { flunk "No DM linking reply in groups" } do
        assert_no_difference "TelegramMessage.count" do
          ProcessTelegramUpdateJob.perform_now(@agent, update)
        end
      end
    end
    assert_equal 0, @agent.reload.telegram_unlinked_messages_count
    assert_nil @agent.telegram_unlinked_last_received_at
  end

  test "stores a direct message from a subscribed user" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)

    assert_difference "TelegramMessage.count", 1 do
      assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
        ProcessTelegramUpdateJob.perform_now(@agent, build_update("hello", username: "daniel_t"))
      end
    end

    telegram_message = subscription.telegram_messages.last
    assert_equal "user", telegram_message.role
    assert_equal "hello", telegram_message.text
    assert_equal "daniel_t", telegram_message.sender_username
    assert_equal "daniel_t", subscription.reload.telegram_username
    assert_equal 0, @agent.reload.telegram_unlinked_messages_count
    assert_nil @agent.telegram_unlinked_last_received_at
  end

  test "triggers an external agent for a subscribed direct message" do
    @agent.update!(
      runtime: "external",
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid"
    )
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, build_update("wake up"))
    end
  end

  test "does not trigger twice for a duplicate Telegram update" do
    @agent.update!(
      runtime: "external",
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid"
    )
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_update("once")

    assert_difference "TelegramMessage.count", 1 do
      2.times { ProcessTelegramUpdateJob.perform_now(@agent, update) }
    end
    assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == "TelegramAgentTriggerJob" }
  end

  test "stores a pending photo and enqueues preparation" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_media_update(
      "photo" => [
        { "file_id" => "small", "file_size" => 100, "width" => 100, "height" => 100 },
        { "file_id" => "large", "file_size" => 200, "width" => 800, "height" => 600 }
      ],
      "caption" => "Look at this"
    )

    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end

    message = subscription.telegram_messages.last
    assert_equal "photo", message.media_kind
    assert_equal "pending", message.media_status
    assert_equal "Look at this", message.caption
    assert_equal "Look at this\n\n[Photo — processing]", message.text
    assert_equal({ "width" => 800, "height" => 600 }, message.media_metadata)
    assert_equal "large", enqueued_jobs.last.fetch("arguments").second
  end

  test "stores voice captions and enqueues preparation" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_media_update(
      "voice" => { "file_id" => "voice-1", "file_size" => 10_000, "duration" => 8 },
      "caption" => "A quick thought"
    )

    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end

    message = subscription.telegram_messages.last
    assert_equal "voice", message.media_kind
    assert_equal "A quick thought\n\n[Voice message — processing]", message.text
    assert_equal 8, message.media_metadata["duration"]
  end

  test "stores a round video note as a video and enqueues preparation" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_media_update(
      "video_note" => { "file_id" => "note-1", "file_size" => 50_000, "duration" => 15, "length" => 384 }
    )

    assert_enqueued_with(job: PrepareTelegramMediaJob) do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end

    message = subscription.telegram_messages.last
    assert_equal "video", message.media_kind
    assert_equal "pending", message.media_status
    assert_nil message.caption
    assert_equal "[Video — processing]", message.text
    assert_equal({ "duration" => 15, "width" => 384, "height" => 384 }, message.media_metadata)
    assert_equal "note-1", enqueued_jobs.last.fetch("arguments").second
  end

  test "does not prepare a duplicate video note twice" do
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_media_update(
      "video_note" => { "file_id" => "note-1", "duration" => 15, "length" => 384 }
    )

    assert_difference "TelegramMessage.count", 1 do
      assert_enqueued_jobs 1, only: PrepareTelegramMediaJob do
        2.times { ProcessTelegramUpdateJob.perform_now(@agent, update) }
      end
    end
  end

  test "rejects oversized video notes before preparation" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_media_update(
      "video_note" => {
        "file_id" => "too-large",
        "file_size" => TelegramMessage.media_limit_for("video") + 1,
        "duration" => 30,
        "length" => 384
      }
    )

    Net::HTTP.stub :post, @fake_ok do
      assert_no_enqueued_jobs only: PrepareTelegramMediaJob do
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end

    message = subscription.telegram_messages.last
    assert_equal "video", message.media_kind
    assert_equal "failed", message.media_status
    assert_equal "too_large", message.media_error
    assert_equal "[Video could not be received]", message.text
  end

  test "rejects oversized video before preparation" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    update = build_media_update(
      "video" => {
        "file_id" => "too-large",
        "file_size" => TelegramMessage.media_limit_for("video") + 1,
        "duration" => 30,
        "width" => 1920,
        "height" => 1080
      }
    )

    Net::HTTP.stub :post, @fake_ok do
      assert_no_enqueued_jobs only: PrepareTelegramMediaJob do
        ProcessTelegramUpdateJob.perform_now(@agent, update)
      end
    end

    message = subscription.telegram_messages.last
    assert_equal "failed", message.media_status
    assert_equal "too_large", message.media_error
    assert_equal "[Video could not be received]", message.text
  end

  test "ignores unsupported media" do
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)

    assert_no_difference "TelegramMessage.count" do
      ProcessTelegramUpdateJob.perform_now(@agent, build_media_update("document" => { "file_id" => "doc" }))
    end
  end

  test "intercepts reset without storing it or triggering the resident" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)

    Net::HTTP.stub :post, @fake_ok do
      assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
        assert_difference "TelegramMessage.count", 1 do
          ProcessTelegramUpdateJob.perform_now(@agent, build_update("/reset"))
        end
      end
    end

    assert_equal 1, subscription.reload.runtime_session_generation
    assert_equal "souls.house", subscription.telegram_messages.last.sender_name
    refute subscription.telegram_messages.exists?(role: "user", text: "/reset")
  end

  test "reset callback verifies the thread and bumps its generation" do
    subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 456)
    methods = []
    responder = lambda do |uri, _body, _headers|
      methods << uri.path
      @fake_ok
    end
    update = {
      "callback_query" => {
        "id" => "callback-1",
        "data" => "safeguard_reset:#{subscription.to_param}",
        "message" => { "chat" => { "id" => 456 } }
      }
    }

    Net::HTTP.stub :post, responder do
      ProcessTelegramUpdateJob.perform_now(@agent, update)
    end

    assert_equal 1, subscription.reload.runtime_session_generation
    assert methods.any? { |path| path.end_with?("/sendMessage") }
    assert methods.any? { |path| path.end_with?("/answerCallbackQuery") }
  end

  private

  def build_update(text, username: nil)
    {
      "update_id" => 123,
      "message" => {
        "message_id" => 1,
        "date" => Time.current.to_i,
        "chat" => { "id" => 456, "type" => "private" },
        "text" => text,
        "from" => { "id" => 789, "username" => username }
      }
    }
  end

  def build_media_update(payload)
    build_update(nil).tap do |update|
      update.fetch("message").delete("text")
      update.fetch("message").merge!(payload)
    end
  end

end
