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
    assert_equal "souls.house", notice.sender_name
    assert_includes notice.text, "copied to souls.house"
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
    assert_equal true, props["can_manage_telegram_groups"]
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

  private

  def sign_in_as(user)
    post login_path, params: { email_address: user.email_address, password: "password123" }
  end

  def inertia_version
    ViteRuby.digest rescue nil
  end

end
