require "test_helper"

# Both halves of visitors in one process (JdWxAj): the home half's real
# Visits::Client talks to the visited half's real /api/v1/visit/* endpoints
# through Rack. Not the two-deployment acceptance run (Mira's), but the wire
# between the two branches, exercised as written.
class VisitorsTwoHalvesTest < ActionDispatch::IntegrationTest

  include WebMock::API

  VISITED = "https://127.0.0.1"

  setup do
    @previous_private = ENV["SOULSHOUSE_ALLOW_PRIVATE_VISIT_ORIGINS"]
    ENV["SOULSHOUSE_ALLOW_PRIVATE_VISIT_ORIGINS"] = "1"
    stub_request(:any, /\Ahttps:\/\/127\.0\.0\.1\//).to_rack(Rails.application)

    @home_agent = agents(:research_assistant)
    @home_agent.update_columns(active: true, paused: false, runtime: "external", trigger_bearer_token: "trigger_secret")
    @visited_account = accounts(:team_account)
    @visited_owner = @visited_account.memberships.confirmed.first.user
    @visited_chat = @visited_account.chats.create!(title: "Visited room", manual_responses: true, model_id: "openrouter/auto", agents: [ agents(:other_account_agent) ])
    @client = Visits::Client.new
    @turns = []
    turns = @turns
    @fake_trigger = Object.new
    @fake_trigger.define_singleton_method(:request_response) do |**kwargs|
      turns << kwargs
      { status: 202, body: { "status" => "queued" } }
    end
  end

  teardown do
    ENV["SOULSHOUSE_ALLOW_PRIVATE_VISIT_ORIGINS"] = @previous_private
    WebMock.reset!
  end

  def start_visit!
    invitation = VisitorInvitation.issue!(account: @visited_account, user: @visited_owner, local_name: "Guest RA")
    response = @client.accept_invitation(origin: VISITED, token: invitation.raw_token, name: @home_agent.name,
      colour: @home_agent.colour, icon: @home_agent.icon, home_origin: "https://home.example")
    assert_equal 201, response.status, response.body
    visit = @home_agent.visits.create!(visited_origin: VISITED, local_name: response.json.dig("visit", "agent", "name"),
      visited_account_name: response.json.dig("visit", "account", "name"), visit_token: response.json["visit_token"])
    visitor = VisitorAdmission.authenticate(response.json["visit_token"]).agent
    @visited_chat.chat_agents.create!(agent: visitor)
    @visited_chat.reload
    [ visit, visitor ]
  end

  def poll!(visit)
    Agents::Endpoint.stub(:url_for, "http://runtime.test") do
      ChaosTriggerClient.stub(:new, @fake_trigger) do
        perform_enqueued_jobs(only: Visits::TriggerWakeJob) { Visits::Poller.new(visit, client: @client).call }
      end
    end
  end

  test "invite, accept, mention, collect, reply under the local alias; a redelivery starts no second home turn" do
    visit, visitor = start_visit!
    assert_equal "Guest RA", visitor.name

    perform_enqueued_jobs(except: ResidentTurnDispatchJob) do
      Messages::PostFromHuman.new(chat: @visited_chat, user: @visited_owner, content: "@Guest RA, hello from the visited house").call
    end
    result = poll!(visit)
    assert_equal :ok, result[:status], result.inspect
    assert_equal 1, result[:enqueued]
    assert_equal 1, @turns.size, "one home turn"
    assert_equal "visit", @turns.first[:trigger_kind]
    refute_includes @turns.first.to_json, visit.visit_token, "no visit token in the trigger"

    wake = visit.visit_wakes.sole
    transcript = @client.conversation(visit, conversation_id: wake.remote_conversation_id, wake_id: wake.remote_wake_id)
    assert_equal 200, transcript.status
    assert_equal "@Guest RA, hello from the visited house", transcript.json["messages"].last["content"]

    reply = @client.post_message(visit, conversation_id: wake.remote_conversation_id, content: "Hello back.",
      wake_id: wake.remote_wake_id)
    assert_equal 201, reply.status, reply.body
    posted = @visited_chat.messages.order(:id).last
    assert_equal "Guest RA", posted.agent.name
    assert posted.agent.visiting?

    # The home never completed the wake, and the lease lapses: the visited
    # house hands it out again. The home must not start a second turn.
    VisitorWake.update_all(lease_expires_at: 1.minute.ago)
    again = poll!(visit)
    assert_equal 1, @turns.size, "redelivered wake, still one home turn: #{again.inspect}"
  end

  test "removed before collection: the home can neither collect nor post, and its visit ends" do
    visit, visitor = start_visit!
    perform_enqueued_jobs(except: ResidentTurnDispatchJob) do
      Messages::PostFromHuman.new(chat: @visited_chat, user: @visited_owner, content: "@Guest RA, second one").call
    end
    visitor.visitor_admission.end!(by: "account")

    result = poll!(visit)
    assert_equal :revoked, result[:status]
    assert_empty @turns
    refute visit.reload.active?
    post = @client.post_message(visit, conversation_id: @visited_chat.to_param, content: "Still here?")
    assert_equal 401, post.status
    assert_equal 0, @visited_chat.messages.where(agent: visitor).count
  end

end
