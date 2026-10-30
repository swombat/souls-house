require "test_helper"
require "ostruct"

# #596: allowing a group, the notice, the owner-only switch, and the rule that
# a group switched off between enqueue and send gets nothing.
class TelegramGroupsTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:team_account)
    @owner = memberships(:team_account_owner).user
    @member = memberships(:team_member).user
    @fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 500, "date" => Time.current.to_i } }.to_json)
    @agent = Net::HTTP.stub :post, @fake_ok do
      @account.agents.create!(name: "Alanis", telegram_bot_token: "4242:ABC", telegram_bot_username: "alanis_bot",
        runtime: "external", endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    end
    @group = @agent.telegram_groups.create!(telegram_chat_id: -100_1, title: "MGL")
  end

  test "an owner allows a group; the notice goes into the group once and is kept in the thread" do
    sign_in_as(@owner)

    assert_enqueued_with(job: TelegramGroupNoticeJob) do
      patch account_agent_telegram_group_path(@account, @agent, @group), params: { allowed: true }
    end
    @group.reload
    assert @group.allowed?
    assert_equal @owner, @group.allowed_by

    posts = []
    Net::HTTP.stub :post, ->(uri, body, _headers) { posts << [ uri.to_s, JSON.parse(body) ]; @fake_ok } do
      perform_enqueued_jobs(only: TelegramGroupNoticeJob)
    end
    assert_equal 1, posts.size
    assert_match(/sendMessage\z/, posts.first[0])
    assert_equal(-100_1, posts.first[1]["chat_id"])
    notice = @group.telegram_messages.sole
    assert_equal Setting.instance.site_name, notice.sender_name
    assert_includes notice.text, "copied to #{Setting.instance.site_name}"
    assert_includes notice.text, @account.name
    assert_includes notice.text, "allowance"
    assert_includes notice.text, "@alanis_bot"
  end

  test "a member who is not an owner cannot allow a group but can read its thread" do
    sign_in_as(@member)

    patch account_agent_telegram_group_path(@account, @agent, @group), params: { allowed: true }
    assert_not @group.reload.allowed?

    get account_agent_telegram_group_path(@account, @agent, @group)
    assert_response :success
  end

  test "only an owner can change bot answers and their allowlist" do
    sign_in_as(@member)
    assert_no_enqueued_jobs only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group),
        params: { answers_bots: true, answer_bot_usernames: [ "other_bot" ] }
    end
    assert_not @group.reload.answers_bots?
    assert_empty @group.answer_bot_usernames
  end

  test "an owner saves normalized bot usernames without changing unrelated attributes" do
    sign_in_as(@owner)
    assert_no_enqueued_jobs only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group),
        params: { answers_bots: true, answer_bot_usernames: [ "@Other_Bot", "SECOND_bot" ],
                  title: "Untrusted title", allowed_by_id: @member.id, telegram_chat_id: -999 }
    end
    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "integrations")
    @group.reload
    assert @group.answers_bots?
    assert_equal [ "other_bot", "second_bot" ], @group.answer_bot_usernames
    assert_not @group.allowed?
    assert_nil @group.allowed_by
    assert_equal "MGL", @group.title
    assert_equal(-100_1, @group.telegram_chat_id)

    patch account_agent_telegram_group_path(@account, @agent, @group), params: { answer_bot_usernames: "" }
    assert_empty @group.reload.answer_bot_usernames
    assert @group.answers_bots?
  end

  test "enabling bot answers in an allowed group announces once, not on list edits or repeated saves" do
    @group.allow!(by: @owner)
    sign_in_as(@owner)
    assert_enqueued_jobs 1, only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group), params: { answers_bots: true }
    end
    assert @group.reload.answers_bots?
    assert_no_enqueued_jobs only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group),
        params: { answers_bots: true, answer_bot_usernames: [ "other_bot" ] }
      patch account_agent_telegram_group_path(@account, @agent, @group), params: { answers_bots: false }
    end
    assert_not @group.reload.answers_bots?
    assert @group.allowed?
  end

  test "enabling a group and bot answers together queues only one notice" do
    sign_in_as(@owner)
    assert_enqueued_jobs 1, only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group),
        params: { allowed: true, answers_bots: true, answer_bot_usernames: [ "@Other_bot" ] }
    end
    @group.reload
    assert @group.allowed?
    assert @group.answers_bots?
    assert_equal @owner, @group.allowed_by
    assert_not_nil @group.allowed_at
  end

  test "invalid bot usernames reject the whole update without a notice" do
    sign_in_as(@owner)
    assert_no_enqueued_jobs only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group),
        params: { allowed: true, answers_bots: true, answer_bot_usernames: [ "not a username!" ] }
    end
    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "integrations")
    assert flash[:alert].present?
    @group.reload
    assert_not @group.allowed?
    assert_not @group.answers_bots?
    assert_empty @group.answer_bot_usernames
    assert_nil @group.allowed_at
  end

  test "a group the bot has left cannot be switched on" do
    @group.update!(removed_at: Time.current)
    sign_in_as(@owner)

    assert_no_enqueued_jobs only: TelegramGroupNoticeJob do
      patch account_agent_telegram_group_path(@account, @agent, @group), params: { allowed: true }
    end
    assert_not @group.reload.allowed?
  end

  test "the settings page lists the group with its state" do
    sign_in_as(@owner)
    get edit_account_agent_path(@account, @agent, tab: "integrations"),
      headers: { "X-Inertia" => "true", "X-Inertia-Version" => inertia_version }

    props = JSON.parse(response.body)["props"]
    assert_equal [ "MGL" ], props["telegram_groups"].map { |group| group["title"] }
    assert_equal false, props["telegram_groups"].first["allowed"]
    assert_equal false, props["telegram_groups"].first["answers_bots"]
    assert_equal [], props["telegram_groups"].first["answer_bot_usernames"]
    assert_equal true, props["can_manage_telegram_groups"]
  end

  # #646 keeps every message the bot receives while a group is on; the page
  # has to mark which of them were addressed to the resident, and say when
  # Telegram's privacy mode means the rest never arrived.
  test "the group page marks addressed rows against context, and reports the bot's privacy mode" do
    @group.update!(answers_bots: true, answer_bot_usernames: [ "other_bot" ])
    @group.telegram_messages.create!(role: "user", text: "Morning all", sender_name: "Pepe", sent_at: 2.minutes.ago, addressed: false)
    @group.telegram_messages.create!(role: "user", text: "Alanis?", sender_name: "Pepe", sent_at: 1.minute.ago, addressed: true)
    @group.telegram_messages.create!(role: "assistant", text: "Here.", sender_name: "Alanis", sent_at: Time.current, telegram_message_id: 77)
    sign_in_as(@owner)

    get account_agent_telegram_group_path(@account, @agent, @group),
      headers: { "X-Inertia" => "true", "X-Inertia-Version" => inertia_version }
    props = JSON.parse(response.body)["props"]
    assert_equal [ [ "user", false ], [ "user", true ], [ "assistant", false ] ],
      props["messages"].map { |message| [ message["role"], message["addressed"] ] }
    assert_equal false, props["privacy_mode_on"], "nothing known from getMe is not a privacy-mode claim"
    assert_equal "alanis_bot", props["agent"]["bot_username"]
    assert_equal true, props["group"]["answers_bots"]
    assert_equal [ "other_bot" ], props["group"]["answer_bot_usernames"]

    @agent.update_column(:telegram_reads_all_group_messages, false)
    get account_agent_telegram_group_path(@account, @agent, @group),
      headers: { "X-Inertia" => "true", "X-Inertia-Version" => inertia_version }
    assert_equal true, JSON.parse(response.body)["props"]["privacy_mode_on"]
  end

  test "a wake queued before the owner switched the group off is not processed" do
    @group.allow!(by: @owner)
    message = @group.telegram_messages.create!(role: "user", text: "@alanis_bot hi", sender_name: "Ana", telegram_message_id: 9, sent_at: Time.current)
    @group.disallow!

    called = false
    ExternalAgentTelegramRequest.stub :new, ->(**) { called = true; OpenStruct.new(call: { status: 200 }) } do
      @agent.stub :external?, true do
        TelegramAgentTriggerJob.perform_now(@group, message)
      end
    end
    assert_not called
  end

  test "a reply asked for after the owner switched the group off is refused, and nothing is sent" do
    @group.allow!(by: @owner)
    api_token = ApiKey.generate_for(@owner, name: "Alanis", agent: @agent).raw_token
    @group.disallow!

    posts = []
    Net::HTTP.stub :post, ->(*args) { posts << args; @fake_ok } do
      post api_v1_telegram_messages_url, params: { reply_to: @group.to_param, text: "late" },
        headers: { "Authorization" => "Bearer #{api_token}" }
    end
    assert_response :not_found
    assert_empty posts
    assert_equal 0, @group.telegram_messages.where(role: "assistant").count
  end

  test "a reply into an allowed group answers the latest message addressed to the bot" do
    @group.allow!(by: @owner)
    @group.telegram_messages.create!(role: "user", text: "@alanis_bot one", sender_name: "Ana", telegram_message_id: 31, sent_at: 2.minutes.ago)
    @group.telegram_messages.create!(role: "user", text: "@alanis_bot two", sender_name: "Ben", telegram_message_id: 32, sent_at: 1.minute.ago)
    api_token = ApiKey.generate_for(@owner, name: "Alanis", agent: @agent).raw_token

    posts = []
    Net::HTTP.stub :post, ->(uri, body, _headers) { posts << JSON.parse(body); @fake_ok } do
      post api_v1_telegram_messages_url, params: { reply_to: @group.to_param, text: "hello both" },
        headers: { "Authorization" => "Bearer #{api_token}" }
    end
    assert_response :created
    assert_equal 1, posts.size
    assert_equal(-100_1, posts.first["chat_id"])
    assert_equal 32, posts.first.dig("reply_parameters", "message_id")
  end

  test "a message that arrives while the turn is generating does not take the reply" do
    @group.allow!(by: @owner)
    ana = @group.telegram_messages.create!(role: "user", text: "@alanis_bot one", sender_name: "Ana", telegram_message_id: 31, sent_at: 2.minutes.ago)
    @agent.agent_runtime_interactions.create!(
      trigger_kind: "telegram", started_at: 1.minute.ago, provider_auth_mode: Agent::PROVIDER_AUTH_MODES.first,
      session_id: "#{@agent.uuid}-telegram-#{@group.id}", last_included_message_id: ana.id
    )
    @group.telegram_messages.create!(role: "user", text: "@alanis_bot me too", sender_name: "Ben", telegram_message_id: 32, sent_at: Time.current)
    api_token = ApiKey.generate_for(@owner, name: "Alanis", agent: @agent).raw_token

    posts = []
    Net::HTTP.stub :post, ->(uri, body, _headers) { posts << JSON.parse(body); @fake_ok } do
      post api_v1_telegram_messages_url, params: { reply_to: @group.to_param, text: "for Ana" },
        headers: { "Authorization" => "Bearer #{api_token}" }
    end
    assert_response :created
    assert_equal 31, posts.sole.dig("reply_parameters", "message_id")
  end

  test "sending to all subscribers never reaches a group" do
    @group.allow!(by: @owner)
    @agent.telegram_subscriptions.create!(user: @owner, telegram_chat_id: 111)
    api_token = ApiKey.generate_for(@owner, name: "Alanis", agent: @agent).raw_token

    chats = []
    Net::HTTP.stub :post, ->(uri, body, _headers) { chats << JSON.parse(body)["chat_id"]; @fake_ok } do
      post api_v1_telegram_messages_url, params: { recipient: "all", text: "news" },
        headers: { "Authorization" => "Bearer #{api_token}" }
    end
    assert_response :created
    assert_equal [ 111 ], chats
  end

  test "the send boundary refuses a group that is not allowed, before any HTTP, for text and media" do
    posts = []
    Net::HTTP.stub :post, ->(*args) { posts << args; @fake_ok } do
      assert_raises(TelegramNotifiable::TelegramGroupNotAllowed) { @agent.telegram_send_message(-100_1, "hi") }
      assert_raises(TelegramNotifiable::TelegramGroupNotAllowed) do
        @agent.telegram_send_document(-100_1, StringIO.new("x"), filename: "x.txt", content_type: "text/plain")
      end
    end
    assert_empty posts

    @group.allow!(by: @owner)
    Net::HTTP.stub :post, ->(*args) { posts << args; @fake_ok } do
      @agent.telegram_send_message(-100_1, "hi")
    end
    assert_equal 1, posts.size

    @group.update!(removed_at: Time.current)
    assert_raises(TelegramNotifiable::TelegramGroupNotAllowed) { @agent.telegram_send_message(-100_1, "gone") }
  end

  test "a media-failure notice for a group switched off after the message arrived is not sent" do
    @group.allow!(by: @owner)
    message = @group.telegram_messages.create!(role: "user", text: "[Photo]", media_kind: "photo", media_status: "pending",
      sender_name: "Ana", telegram_message_id: 12, sent_at: Time.current)
    @group.disallow!

    posts = []
    Net::HTTP.stub :post, ->(*args) { posts << args; @fake_ok } do
      PrepareTelegramMediaJob.new.send(:notify_media_failure, message, "too_large")
    end
    assert_empty posts
  end

  test "a safeguard-labelled reply to a group switched off sends neither the notice nor the reply" do
    @group.allow!(by: @owner)
    api_token = ApiKey.generate_for(@owner, name: "Alanis", agent: @agent).raw_token
    detected = OpenStruct.new(detected?: true, prefilter_reason: "x", classifier_verdict: "y", classifier_reason: "z", detector_version: "t")
    posts = []
    revoke_on_lookup = lambda do |*|
      @group.disallow!
      detected
    end

    SafeguardResponseCheck.stub :new, ->(**) { OpenStruct.new(call: revoke_on_lookup.call) } do
      Net::HTTP.stub :post, ->(*args) { posts << args; @fake_ok } do
        post api_v1_telegram_messages_url, params: { reply_to: @group.to_param, text: "I can't help with that." },
          headers: { "Authorization" => "Bearer #{api_token}" }
      end
    end
    assert_empty posts
    assert_equal 0, @group.telegram_messages.count
  end

  private

  def sign_in_as(user)
    post login_path, params: { email_address: user.email_address, password: "password123" }
  end

  def inertia_version
    ViteRuby.digest rescue nil
  end

end
