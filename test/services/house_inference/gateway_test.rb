require 'test_helper'

class HouseInference::GatewayTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID)
    @grant = HouseInferenceGrant.assign!(@agent, users(:user_1))
    @input = { 'model' => @agent.model_id, 'stream' => true, 'messages' => [ { 'role' => 'user', 'content' => 'hello' } ] }
  end

  def upstream(chunks, status: '200')
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new('1.1', status, 'test')
    response.define_singleton_method(:read_body) { |&block| chunks.each(&block) }
    http = Object.new
    %w[use_ssl open_timeout read_timeout write_timeout max_retries].each do |name|
      http.define_singleton_method("#{name}=") { |_| }
    end
    http.define_singleton_method(:request) do |request, &block|
      raise 'missing upstream bearer' unless request['Authorization'] == 'Bearer test-house-only'
      block.call(response)
    end
    HouseInference::Offering.stub(:key, 'test-house-only') do
      Net::HTTP.stub(:new, http) { yield }
    end
  end

  test 'structured nonstreaming completions use the same ledger' do
    @input['stream'] = false
    @input['response_format'] = { 'type' => 'json_object' }
    result = nil
    upstream([ JSON.generate({ 'id' => 'gen-json', 'choices' => [ { 'message' => { 'role' => 'assistant', 'content' => '{}' } } ], 'usage' => { 'cost' => 0.005 } }) ]) do
      result = HouseInference::Gateway.new(agent: @agent, input: @input).call
    end
    assert_equal '{}', result.dig('choices', 0, 'message', 'content')
    assert_equal BigDecimal('0.005'), @grant.spent
  end

  test 'a resident on a paid plan is charged to its plan, not the attached free grant' do
    sub = ResidentSubscription.create!(agent: @agent, account: @agent.account, stripe_subscription_id: 'sub_gateway',
      tier: 'conversation', stripe_status: 'active')
    entitlement = ResidentEntitlement.for_agent!(@agent)
    entitlement.apply_subscription!(sub)
    @input['stream'] = false
    upstream([ JSON.generate({ 'id' => 'gen-paid', 'choices' => [ { 'message' => { 'role' => 'assistant', 'content' => 'hi' } } ], 'usage' => { 'cost' => 0.004 } }) ]) do
      HouseInference::Gateway.new(agent: @agent, input: @input).call
    end
    assert_equal BigDecimal('0'), @grant.spent
    assert_equal BigDecimal('0.004'), entitlement.reload.allowance_spent
    call = entitlement.house_inference_calls.sole
    assert_equal [ @agent.id, nil, 'settled' ], [ call.agent_id, call.house_inference_grant_id, call.status ]
  end

  test 'streams split SSE tool and usage frames and settles actual cost' do
    chunks = [ "data: {\"id\":\"gen-1\",\"model\":\"deepseek/deepseek-v4.1-flash\",\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n",
      "data: {\"usage\":{\"cost\":0.", "002}}\n\ndata: [DONE]\n\n" ]
    output = +''
    upstream(chunks) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |chunk| output << chunk } }
    assert_includes output, @agent.model_id
    assert_includes output, '[DONE]'
    assert_equal BigDecimal('0.002'), @grant.spent
    assert_equal 'settled', @grant.house_inference_calls.last.status
  end

  test 'a failure before any generation releases the reservation' do
    # Truncated stream with no generation id, a provider error, and the
    # resident's side dropping the stream: none reached a model's output.
    upstream([ "data: {}\n\n" ]) do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    upstream([], status: '503') do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    upstream([ "data: {}\n\n" ]) do
      assert_raises(HouseInference::Error) do
        HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| raise IOError }
      end
    end
    assert_equal BigDecimal('0'), @grant.spent
    assert_equal [ 'released' ] * 3, @grant.house_inference_calls.order(:id).pluck(:status)
    assert_equal [ nil, 503, nil ], @grant.house_inference_calls.order(:id).pluck(:http_status)
  end

  test 'every refused status releases and records the status, never the body' do
    refusal = JSON.generate({ 'error' => { 'code' => 404, 'message' => 'No endpoints found that can handle the requested parameters.' } })
    [ [ '404', refusal ], [ '408', '' ], [ '400', refusal ], [ '404', 'not json' ], [ '402', '' ],
      [ '429', refusal ], [ '502', refusal ] ].each do |status, body|
      upstream([ body ], status: status) do
        assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
      end
      call = @grant.house_inference_calls.order(:id).last
      assert_equal [ 'released', BigDecimal('0'), status.to_i ], [ call.status, call.charge_usd, call.http_status ], status
    end
    assert_equal BigDecimal('0'), @grant.spent
  end

  def broken_stream(*frames, &block)
    chunks = frames.map { |frame| "data: #{JSON.generate(frame)}\n\n" }
    upstream(chunks) do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call(&block || ->(_) {}) }
    end
    @grant.house_inference_calls.order(:id).last
  end

  test 'an id or a role-only frame is not output: the call is released, keeping the id' do
    call = broken_stream({ 'id' => 'gen-role', 'choices' => [ { 'delta' => { 'role' => 'assistant', 'content' => '' } } ] })
    assert_equal [ 'released', BigDecimal('0'), 'gen-role' ], [ call.status, call.charge_usd, call.upstream_id ]
    # The same, broken on the resident's side instead of the provider's.
    call = broken_stream({ 'id' => 'gen-role-2', 'choices' => [ { 'delta' => { 'role' => 'assistant' } } ] }) { |_| raise IOError }
    assert_equal [ 'released', 'gen-role-2' ], [ call.status, call.upstream_id ]
  end

  test 'a stream that produced text, a tool call or reasoning and then broke keeps the conservative charge' do
    [ { 'content' => 'hel' },
      { 'tool_calls' => [ { 'index' => 0, 'function' => { 'name' => 'lookup' } } ] },
      { 'reasoning' => 'thinking' } ].each_with_index do |delta, i|
      call = broken_stream({ 'id' => "gen-cut-#{i}", 'choices' => [ { 'delta' => { 'role' => 'assistant' }.merge(delta) } ] })
      assert_equal [ 'uncertain', BigDecimal('0.75'), "gen-cut-#{i}" ], [ call.status, call.charge_usd, call.upstream_id ], delta.keys.first
    end
  end

  test 'a broken stream that reported its usage settles at that cost' do
    call = broken_stream({ 'id' => 'gen-usage', 'choices' => [ { 'delta' => { 'content' => 'hi' } } ] }, { 'usage' => { 'cost' => 0.003 } })
    assert_equal [ 'settled', BigDecimal('0.003') ], [ call.status, call.charge_usd ]
  end

  test 'arbitrary model fails before a call is reserved' do
    @input['model'] = 'expensive/other-model'
    assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    assert_equal 0, @grant.house_inference_calls.count
  end

  test 'a Haiku resident is billed on the Anthropic route and cannot ask for the other house model' do
    @agent.update!(model_id: HouseInference::Offering::HAIKU_MODEL_ID)
    deepseek = @input.merge('model' => HouseInference::Offering::DEEPSEEK_MODEL_ID)
    error = assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: deepseek).call { |_| } }
    assert_equal 403, error.status
    assert_equal 0, @grant.house_inference_calls.count

    chunks = [ "data: {\"id\":\"gen-h\",\"model\":\"anthropic/claude-haiku-5.5\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
      "data: {\"usage\":{\"cost\":0.0004}}\n\ndata: [DONE]\n\n" ]
    output = +''
    @input['model'] = HouseInference::Offering::HAIKU_MODEL_ID
    upstream(chunks) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |chunk| output << chunk } }
    assert_includes output, '"model":"house/claude-haiku-5.5"'
    call = @grant.house_inference_calls.last
    assert_equal [ 'anthropic', 'house/claude-haiku-5.5', 'settled' ], [ call.provider_route, call.model_id, call.status ]
    assert_equal BigDecimal('0.0004'), @grant.spent
  end

end
