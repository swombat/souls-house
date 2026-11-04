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

  test 'every refused status releases and records the status and a sanitised reason, never the body' do
    refusal = JSON.generate({ 'error' => { 'code' => 404, 'message' => 'No endpoints found that can handle the requested parameters.' } })
    [ [ '404', refusal ], [ '408', '' ], [ '400', refusal ], [ '404', 'not json' ], [ '402', '' ],
      [ '429', refusal ], [ '502', refusal ] ].each do |status, body|
      upstream([ body ], status: status) do
        assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
      end
      call = @grant.house_inference_calls.order(:id).last
      assert_equal [ 'released', BigDecimal('0'), status.to_i ], [ call.status, call.charge_usd, call.http_status ], status
      expected = { refusal => 'code 404: no provider endpoint accepts this request',
        '' => nil, 'not json' => 'unreadable body (8 bytes)' }.fetch(body)
      expected.nil? ? assert_nil(call.refusal_reason, status) : assert_equal(expected, call.refusal_reason, status)
    end
    assert_equal BigDecimal('0'), @grant.spent
  end

  test 'a provider 400 keeps its type and field path, and nothing the resident wrote' do
    secret = 'Dear diary, the password is hunter2'
    raw = JSON.generate({ 'type' => 'error', 'error' => { 'type' => 'invalid_request_error',
      'message' => "messages.3.content.0.text: Input should be a valid string, got \"#{secret}\" and 'it\\'s #{secret}' and «#{secret}» and #{secret}" } })
    body = JSON.generate({ 'error' => { 'code' => 400, 'message' => 'Provider returned error',
      'metadata' => { 'provider_name' => 'Anthropic', 'raw' => raw } } })
    error = nil
    upstream([ body ], status: '400') do
      error = assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    call = @grant.house_inference_calls.order(:id).last
    assert_equal 'Anthropic code 400 invalid_request_error: messages.3.content.0.text: invalid value, expected string',
      call.refusal_reason
    assert_equal call.refusal_reason, error.reason
    refute_match(/diary|hunter2|password/, call.refusal_reason)
    refute_includes error.message, 'messages.3'
  end

  # Mira's round-1 reproductions (PR #760): escaped single quotes, guillemets,
  # and prose the house has no shape for. No provider text is copied.
  test 'refusal reasons fail closed: unknown prose is withheld, known shapes are house sentences' do
    reason = ->(message, **extra) { HouseInference::RefusalReason.call(JSON.generate({ 'error' => { 'code' => 400, 'message' => message }.merge(extra) })) }
    [ "got 'it\\'s hunter2'", 'got «hunter2»', 'hunter2', "Your note said: hunter2 is the password",
      "messages.0.content: hunter2 hunter2" ].each do |message|
      result = reason.(message)
      refute_match(/hunter2|password|note/, result, message)
      assert_match(/detail withheld\z/, result, message)
    end
    assert_equal 'code 400: messages.0.content: detail withheld', reason.('messages.0.content: hunter2 hunter2')
    # A path stops at its first segment that isn't a known request key.
    assert_equal 'code 400: tools.2.input_schema.properties.…: required field missing',
      reason.('tools.2.input_schema.properties.secret_plan.type: Field required')
    assert_equal 'code 400: detail withheld', reason.('hunter2.diary: whatever')
    assert_equal 'code 400: prompt too long: 250000 tokens > 200000 maximum',
      reason.("prompt is too long: 250000 tokens > 200000 maximum\n\tsee \"hunter2")
    assert_equal 'code 400: max_tokens: max_tokens 64001 above the model maximum 64000',
      reason.('max_tokens: 64001 > 64000, which is the maximum allowed number of output tokens for claude-haiku')
    assert_equal 'code 400: input 190000 + max_tokens 64000 exceeds the context limit 200000',
      reason.('input length and `max_tokens` exceed context limit: 190000 + 64000 > 200000, decrease input length')
    assert_equal 'code 400: thinking: field not accepted', reason.('thinking: Extra inputs are not permitted')
    # Soul Horse's refusal (#725), Anthropic's wording, reproduced 2026-11-04.
    assert_equal 'code 400: the request ends with an assistant message, which this model refuses (no prefill)',
      reason.('This model does not support assistant message prefill. The conversation must end with a user message.')
    assert_equal 'code 400: detail withheld', reason.('Input should be a valid hunter2')
    long = reason.('x' * 1000, 'type' => 'a' * 40)
    assert_operator long.length, :<=, 300
    assert_nil HouseInference::RefusalReason.call('   ')
    assert_equal 'no error field', HouseInference::RefusalReason.call('{"ok":true}')
    # A provider name that is not a plain identifier is dropped, not echoed;
    # a non-JSON raw is prose like any other.
    odd = HouseInference::RefusalReason.call(JSON.generate({ 'error' => { 'code' => 400, 'message' => 'bad',
      'metadata' => { 'provider_name' => "Anthropic\" <script>", 'raw' => 'plain text with "hunter2"' } } }))
    assert_equal 'code 400: detail withheld', odd
  end

  test 'only the first 64 KiB of a refusal body is read, and the rest is never drained' do
    consumed = 0
    chunks = Enumerator.new { |y| loop { consumed += 1; y << ('m' * 10_000) } }
    upstream(chunks, status: '400') do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    call = @grant.house_inference_calls.order(:id).last
    assert_equal [ 'released', BigDecimal('0'), 400, 'unreadable body (65536 bytes)' ],
      [ call.status, call.charge_usd, call.http_status, call.refusal_reason ]
    assert_equal 7, consumed
  end

  test 'reading a refusal body stops at the call deadline' do
    response = Object.new
    consumed = 0
    response.define_singleton_method(:read_body) { |&block| loop { consumed += 1; block.call('x' * 10) } }
    now = 0
    clock = -> { now += 1 }
    assert_equal 'x' * 20, HouseInference::Gateway.bounded_body(response, deadline: 2.5, clock: clock)
    assert_equal 2, consumed
    consumed = 0
    assert_equal '', HouseInference::Gateway.bounded_body(response, deadline: 0, clock: -> { 1 })
    assert_equal 0, consumed, 'a call already past its deadline reads nothing'
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

  test 'usage without a known cost does not stop a call with no output from being released' do
    role = { 'id' => 'gen-empty-usage', 'choices' => [ { 'delta' => { 'role' => 'assistant' } } ] }
    [ {}, { 'prompt_tokens' => 12, 'completion_tokens' => 0 } ].each do |usage|
      call = broken_stream(role, { 'usage' => usage })
      assert_equal [ 'released', BigDecimal('0'), 'gen-empty-usage' ], [ call.status, call.charge_usd, call.upstream_id ], usage.inspect
    end
    # A known cost with no output still settles at that cost.
    call = broken_stream(role, { 'usage' => { 'cost' => 0.0001 } })
    assert_equal [ 'settled', BigDecimal('0.0001') ], [ call.status, call.charge_usd ]
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
