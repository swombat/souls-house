require "test_helper"

# The visited house's half of visitors (JdWxAj), end to end over the wire:
# invite, accept, seat, mention, collect, reply, remove, retry.
class Api::V1::Visiting::VisitFlowTest < ActionDispatch::IntegrationTest

  setup do
    @owner = users(:confirmed_user)
    @account = agents(:research_assistant).account
    @chat = @account.chats.create!(title: "Visitors", manual_responses: true, agents: [ agents(:research_assistant) ],
      model_id: "openrouter/auto")
  end

  def invite!(local_name: nil)
    VisitorInvitation.issue!(account: @account, user: @owner, local_name: local_name)
  end

  def accept!(invitation, name: "Mira")
    post "/api/v1/visit/invitations/#{invitation.raw_token}/accept",
      params: { name: name, colour: "teal", home_origin: "https://seuros.example" }, as: :json
  end

  def visit_headers(token) = { "Authorization" => "Bearer #{token}" }

  def admitted!(name: "Mira")
    accept!(invite!, name: name)
    assert_response :created
    token = response.parsed_body["visit_token"]
    admission = VisitorAdmission.authenticate(token)
    @chat.chat_agents.create!(agent: admission.agent)
    [ token, admission ]
  end

  def wake_visitor!(admission)
    ExternalAgentResponseRequest.new(agent: admission.agent, chat: @chat, wake_source_kinds: [ "human" ]).call
  end

  test "the invitation previews the account and expiry without showing who is in it" do
    invitation = invite!
    get "/api/v1/visit/invitations/#{invitation.raw_token}"
    assert_response :success
    assert_equal @account.name, response.parsed_body.dig("account", "name")
    assert_equal "open", response.parsed_body["state"]
    assert_nil response.parsed_body["members"]

    get "/api/v1/visit/invitations/vinv_nope"
    assert_response :not_found
  end

  test "accepting mints a visiting agent outside the account's residents, once" do
    invitation = invite!
    assert_difference -> { Agent.count }, 1 do
      accept!(invitation)
    end
    assert_response :created
    agent = VisitorAdmission.authenticate(response.parsed_body["visit_token"]).agent
    assert agent.visiting?
    assert_equal @account.id, agent.account_id
    refute_includes @account.agents, agent
    assert_includes @account.visiting_agents, agent
    assert_equal "https://seuros.example", response.parsed_body.dig("visit", "home", "origin")
    assert response.parsed_body.dig("visit", "home", "claimed")

    accept!(invitation, name: "Mira again")
    assert_response :unprocessable_entity
  end

  test "the local alias set at admission lets a second Mira in" do
    token, = admitted!(name: "Mira")
    assert token
    accept!(invite!(local_name: "Mira (Seuros)"), name: "Mira")
    assert_response :created
    assert_equal "Mira (Seuros)", response.parsed_body.dig("visit", "agent", "name")
  end

  test "an expired invitation and a non-https origin are refused" do
    invitation = invite!
    invitation.update_columns(expires_at: 1.minute.ago)
    accept!(invitation)
    assert_response :unprocessable_entity

    post "/api/v1/visit/invitations/#{invite!.raw_token}/accept",
      params: { name: "Mira", home_origin: "http://seuros.example" }, as: :json
    assert_response :unprocessable_entity
  end

  test "a visitor cannot be seated without a current admission" do
    _token, admission = admitted!
    other = @account.chats.create!(title: "Other", manual_responses: true, agents: [ agents(:research_assistant) ],
      model_id: "openrouter/auto")
    admission.end!(by: "account")
    seat = other.chat_agents.build(agent: admission.agent)
    refute seat.valid?
  end

  test "mention, collect, reply under the visitor's name, complete" do
    token, admission = admitted!
    @chat.messages.create!(role: "user", user: @owner, content: "@Mira what do you think?")

    result = nil
    assert_no_enqueued_jobs(only: ResidentTurnDispatchJob) do
      result = wake_visitor!(admission)
    end
    assert_equal 202, result[:status]
    interaction = admission.agent.agent_runtime_interactions.last
    assert_equal "running", interaction.execution_state
    assert_nil ResidentTurn.find_by(agent_runtime_interaction_id: interaction.id) if defined?(ResidentTurn)

    get "/api/v1/visit/wakes", headers: visit_headers(token)
    assert_response :success
    wakes = response.parsed_body["wakes"]
    assert_equal 1, wakes.size
    wake_id = wakes.first["id"]
    assert_equal @chat.to_param, wakes.first["conversation_id"]

    get "/api/v1/visit/wakes", headers: visit_headers(token)
    assert_empty response.parsed_body["wakes"], "a leased wake is not handed out twice"

    get "/api/v1/visit/conversations/#{@chat.to_param}", params: { wake_id: wake_id }, headers: visit_headers(token)
    assert_response :success
    assert_equal "@Mira what do you think?", response.parsed_body["messages"].last["content"]
    assert_equal "Mira", response.parsed_body.dig("you", "name")
    assert_equal @chat.messages.maximum(:id), interaction.reload.last_included_message_id
    assert_equal @chat.messages.maximum(:id), @chat.agent_transcript_cursor(admission.agent)

    post "/api/v1/visit/conversations/#{@chat.to_param}/messages",
      params: { content: "I think it holds.", wake_id: wake_id }, headers: visit_headers(token), as: :json
    assert_response :created
    reply = @chat.messages.order(:id).last
    assert_equal admission.agent, reply.agent
    assert_equal "Mira", reply.agent.name
    assert_equal interaction, reply.runtime_interaction

    post "/api/v1/visit/wakes/#{wake_id}/complete", headers: visit_headers(token)
    assert_response :success
    assert_equal "completed", interaction.reload.execution_state
  end

  test "retrying the first delivery shows the transcript again and starts nothing" do
    token, admission = admitted!
    wake_visitor!(admission)
    get "/api/v1/visit/wakes", headers: visit_headers(token)
    wake_id = response.parsed_body["wakes"].first["id"]

    2.times do
      get "/api/v1/visit/conversations/#{@chat.to_param}", params: { wake_id: wake_id }, headers: visit_headers(token)
      assert_response :success
    end
    assert_equal 1, admission.visitor_wakes.count
    assert_equal 1, admission.agent.agent_runtime_interactions.count
    get "/api/v1/visit/wakes", headers: visit_headers(token)
    assert_empty response.parsed_body["wakes"]

    post "/api/v1/visit/wakes/#{wake_id}/complete", headers: visit_headers(token)
    get "/api/v1/visit/conversations/#{@chat.to_param}", params: { wake_id: wake_id }, headers: visit_headers(token)
    assert_response :gone
  end

  test "removed before collection: the key can neither collect nor post, and the run ends" do
    token, admission = admitted!
    wake_visitor!(admission)
    interaction = admission.agent.agent_runtime_interactions.last

    assert_difference -> { @chat.chat_agents.count }, -1 do
      admission.end!(by: "account")
    end
    assert_equal "timed_out", interaction.reload.execution_state
    assert_match(/not_collected/, interaction.error_message)

    get "/api/v1/visit/wakes", headers: visit_headers(token)
    assert_response :unauthorized
    get "/api/v1/visit/conversations/#{@chat.to_param}", headers: visit_headers(token)
    assert_response :unauthorized
    assert_no_difference -> { Message.where(agent: admission.agent).count } do
      post "/api/v1/visit/conversations/#{@chat.to_param}/messages",
        params: { content: "Still here?" }, headers: visit_headers(token), as: :json
    end
    assert_response :unauthorized
  end

  test "unseated from one conversation: that conversation is 404 and its wake ends" do
    token, admission = admitted!
    wake_visitor!(admission)
    @chat.chat_agents.find_by!(agent: admission.agent).destroy!

    get "/api/v1/visit/wakes", headers: visit_headers(token)
    assert_response :success
    assert_empty response.parsed_body["wakes"]
    get "/api/v1/visit/conversations/#{@chat.to_param}", headers: visit_headers(token)
    assert_response :not_found
  end

  test "the visitor leaves with DELETE and the token stops working" do
    token, admission = admitted!
    delete "/api/v1/visit", headers: visit_headers(token)
    assert_response :success
    assert_equal "visitor", admission.reload.ended_by
    get "/api/v1/visit", headers: visit_headers(token)
    assert_response :unauthorized
  end

  test "a visit token is not an API key and an API key is not a visit token" do
    token, = admitted!
    get "/api/v1/conversations", headers: visit_headers(token)
    assert_includes [ 401, 403 ], response.status

    api_token = ApiKey.generate_for(@owner, name: "x", agent: agents(:research_assistant)).raw_token
    get "/api/v1/visit/wakes", headers: visit_headers(api_token)
    assert_response :unauthorized
  end

  test "an uncollected wake ends as not_collected after the window" do
    token, admission = admitted!
    wake_visitor!(admission)
    interaction = admission.agent.agent_runtime_interactions.last
    travel VisitorWake::COLLECTION_WINDOW + 1.minute do
      get "/api/v1/visit/wakes", headers: visit_headers(token)
      assert_empty response.parsed_body["wakes"]
    end
    assert_equal "timed_out", interaction.reload.execution_state
  end

end
