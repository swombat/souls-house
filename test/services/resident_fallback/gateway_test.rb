require "test_helper"

class ResidentFallback::GatewayTest < ActiveSupport::TestCase

  include ActionMailer::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @agent.account.update_columns(openrouter_api_key: "sk-or-own")
    @chat = @agent.account.chats.create!(title: "Fallback gateway", manual_responses: true, agents: [ @agent ])
    Setting.instance.update!(paid_fallback_enabled: true)
    @policy = ResidentFallbackPolicy.create!(agent: @agent, enabled: true, model_id: "anthropic/claude-sonnet-5", cap_usd: 1,
      enabled_by_user: users(:user_1), enabled_at: Time.current)
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    @turn = ResidentFallbackTurn.create!(agent: @agent, chat: @chat, fallback_interaction: @run, primary_provider: "openai",
      primary_model: "openai/gpt-5", fallback_model_id: "anthropic/claude-sonnet-5", upstream_model: "anthropic/claude-sonnet-5")
    @input = { "model" => "fallback/anthropic/claude-sonnet-5", "stream" => false, "max_tokens" => 1_000,
      "messages" => [ { "role" => "user", "content" => "hello" } ] }
  end

  # A fake upstream: records what was sent; `connect` raises to simulate a
  # connection that never opened.
  def upstream(body: nil, status: "200", connect: nil)
    sent = {}
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "test")
    response.define_singleton_method(:read_body) { |&block| [ body.to_s ].each(&block) }
    http = Object.new
    %w[use_ssl open_timeout read_timeout write_timeout max_retries].each { |name| http.define_singleton_method("#{name}=") { |_| } }
    http.define_singleton_method(:start) { connect ? raise(connect) : (@started = true) }
    http.define_singleton_method(:started?) { @started == true }
    http.define_singleton_method(:finish) { @started = false }
    http.define_singleton_method(:request) do |request, &block|
      sent[:authorization] = request["Authorization"]
      sent[:body] = JSON.parse(request.body)
      block.call(response)
    end
    HouseInference::Offering.stub(:key, "sk-or-house") do
      Net::HTTP.stub(:new, http) { yield sent }
    end
    sent
  end

  def gateway(run_id: @run.id) = ResidentFallback::Gateway.new(agent: @agent, input: @input, run_id: run_id.to_s)

  def completion(cost: 0.01)
    JSON.generate({ "id" => "gen-fb", "choices" => [ { "message" => { "role" => "assistant", "content" => "hi" } } ],
      "usage" => { "cost" => cost, "is_byok" => true, "cost_details" => { "upstream_inference_cost" => 0.2 } } })
  end

  test "serves the fallback turn on the account's own key, pinned to the vendor at list price, and settles the reported cost" do
    sent = upstream(body: completion(cost: 0.01)) { gateway.call }
    assert_equal "Bearer sk-or-own", sent[:authorization]
    assert_equal "anthropic/claude-sonnet-5", sent[:body]["model"]
    assert_equal({ "only" => [ "anthropic" ], "allow_fallbacks" => false, "require_parameters" => true,
      "max_price" => { "prompt" => 2, "completion" => 10 }, "data_collection" => "deny" }, sent[:body]["provider"])
    call = ResidentFallbackCall.sole
    assert_equal [ "settled", BigDecimal("0.21"), "openrouter_usage_cost", @turn.id ], [ call.status, call.charge_usd, call.cost_source, call.resident_fallback_turn_id ]
  end

  test "refuses outside an open fallback turn, with the switch off, or on another model" do
    other = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation", session_id: "x",
      conversation_obfuscated_id: @chat.to_param, requested_by: "souls.house", started_at: Time.current)
    { -> { gateway(run_id: other.id) } => "fallback_off",
      -> { gateway(run_id: "") } => "fallback_off",
      -> { Setting.instance.update!(paid_fallback_enabled: false); gateway } => "fallback_off" }.each do |build, code|
      error = assert_raises(HouseInference::Error) { upstream(body: completion) { build.call.call } }
      assert_equal code, error.code
      Setting.instance.update!(paid_fallback_enabled: true)
    end
    @input["model"] = "fallback/anthropic/claude-opus-5.5"
    error = assert_raises(HouseInference::Error) { upstream(body: completion) { gateway.call } }
    assert_equal "fallback_model_unavailable", error.code
    @input["model"] = "fallback/anthropic/claude-sonnet-5"
    @run.update!(finished_at: Time.current)
    error = assert_raises(HouseInference::Error) { upstream(body: completion) { gateway.call } }
    assert_equal "fallback_off", error.code, "a finished run's turn is closed"
    assert_equal 0, ResidentFallbackCall.count
  end

  test "a call whose worst case doesn't fit the cap is refused with 402 and nothing is sent" do
    @input["max_tokens"] = 32_000
    @input["messages"] = [ { "role" => "user", "content" => "x" * 200_000 } ]
    sent = nil
    error = assert_raises(HouseInference::Error) { sent = upstream(body: completion) { gateway.call } }
    assert_equal [ "fallback_cap_reached", 402 ], [ error.code, error.status ]
    assert_equal 0, ResidentFallbackCall.count
  end

  test "an upstream refusal keeps the whole reservation: the owner's key may have been billed" do
    error = assert_raises(HouseInference::Error) { upstream(body: '{"error":{"message":"no"}}', status: "500") { gateway.call } }
    assert_equal "fallback_provider_refused", error.code
    call = ResidentFallbackCall.sole
    assert_equal [ "unresolved", 500 ], [ call.status, call.http_status ]
    assert_equal call.reservation_usd, @policy.committed_usd
  end

  test "output without a known cost stays unresolved, never settled at nothing" do
    body = JSON.generate({ "id" => "gen-x", "choices" => [ { "message" => { "role" => "assistant", "content" => "hi" } } ], "usage" => {} })
    upstream(body: body) { gateway.call }
    assert_equal "unresolved", ResidentFallbackCall.sole.status
  end

  test "a connection that never opened costs nothing" do
    assert_raises(HouseInference::Error) { upstream(body: completion, connect: Errno::ECONNREFUSED) { gateway.call } }
    call = ResidentFallbackCall.sole
    assert_equal [ "not_sent", BigDecimal("0") ], [ call.status, call.charge_usd ]
  end

  test "images are refused before anything is reserved" do
    @input["messages"] = [ { "role" => "user", "content" => [ { "type" => "image_url", "image_url" => { "url" => "data:x" } } ] } ]
    assert_raises(HouseInference::Error) { upstream(body: completion) { gateway.call } }
    assert_equal 0, ResidentFallbackCall.count
  end

  test "an owner's model change between building the body and admission refuses before anything is sent (Mira #887)" do
    @policy.update!(model_id: "anthropic/claude-opus-5.5")
    @turn.update!(fallback_model_id: "anthropic/claude-opus-5.5")
    @input["model"] = "fallback/anthropic/claude-opus-5.5"
    build = HouseInference::Request.method(:build)
    edit = lambda do |input, offering|
      body = build.call(input, offering)
      # The owner switches to the cheaper model while this call is prepared.
      ResidentFallbackPolicy.find(@policy.id).update!(model_id: "anthropic/claude-sonnet-5")
      body
    end
    sent = nil
    error = HouseInference::Request.stub(:build, edit) do
      assert_raises(HouseInference::Error) { sent = upstream(body: completion) { gateway.call } }
    end
    assert_equal "fallback_model_unavailable", error.code
    assert_equal 0, ResidentFallbackCall.count
    assert_nil sent&.dig(:body), "nothing reached the provider"
  end

  test "the owner is told on the first paid call that reached the provider, once a cap period, and again after off and on" do
    assert_no_enqueued_emails do
      assert_raises(HouseInference::Error) { upstream(body: completion, connect: Errno::ECONNREFUSED) { gateway.call } }
    end
    assert_nil @policy.reload.use_notice_at, "a call that never left the house isn't use"

    assert_enqueued_emails(1) { upstream(body: completion(cost: 0.01)) { gateway.call } }
    assert_not_nil @policy.reload.use_notice_at
    assert_no_enqueued_emails { upstream(body: completion(cost: 0.01)) { gateway.call } }

    travel_to(@policy.period_end + 1.minute) do
      assert_enqueued_emails(1) { upstream(body: completion(cost: 0.01)) { gateway.call } }
      assert_no_enqueued_emails { upstream(body: completion(cost: 0.01)) { gateway.call } }
      @policy.reload.update!(use_notice_at: nil) # what turning it off and on does
      assert_enqueued_emails(1) { upstream(body: completion(cost: 0.01)) { gateway.call } }
    end
  end

  test "an unpriced call still counts as use: its reservation is held, so the owner hears" do
    unpriced = JSON.generate({ "id" => "gen-fb", "choices" => [ { "message" => { "role" => "assistant", "content" => "hi" } } ] })
    assert_enqueued_emails(1) { upstream(body: unpriced) { gateway.call } }
    assert_equal "unresolved", ResidentFallbackCall.sole.status
  end

  test "if the notice can't be queued, the claim rolls back and the next paid call tries again" do
    ResidentFallbackMailer.stub(:first_use, ->(*) { raise "queue down" }) do
      upstream(body: completion(cost: 0.01)) { gateway.call }
    end
    assert_equal "settled", ResidentFallbackCall.sole.status, "the call itself is unaffected"
    assert_nil @policy.reload.use_notice_at
    assert_enqueued_emails(1) { upstream(body: completion(cost: 0.01)) { gateway.call } }
  end

end
