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

  test 'truncated stream disconnect and provider failure retain bounded charge' do
    upstream([ "data: {}\n\n" ]) do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    assert_equal BigDecimal('0.75'), @grant.spent
    upstream([], status: '503') do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    assert_equal BigDecimal('1.5'), @grant.spent
    upstream([ "data: {}\n\n" ]) do
      assert_raises(HouseInference::Error) do
        HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| raise IOError }
      end
    end
    assert_equal BigDecimal('2.25'), @grant.spent
    assert_not @grant.house_inference_calls.where(status: 'pending').exists?
  end

  test 'only the routing refusal releases its reservation; other 4xx and 5xx keep it' do
    refusal = JSON.generate({ 'error' => { 'code' => 404, 'message' => 'No endpoints found that can handle the requested parameters. To learn more about provider routing, visit: https://openrouter.ai/docs' } })
    upstream([ refusal ], status: '404') do
      assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
    end
    call = @grant.house_inference_calls.last
    assert_equal [ 'settled', BigDecimal('0') ], [ call.status, call.charge_usd ]
    assert_equal BigDecimal('0'), @grant.spent

    spent = BigDecimal('0')
    [ [ '408', '' ], [ '400', refusal ], [ '404', JSON.generate({ 'error' => { 'message' => 'Model not found' } }) ],
      [ '404', 'not json' ], [ '429', refusal ], [ '502', refusal ] ].each do |status, body|
      upstream([ body ], status: status) do
        assert_raises(HouseInference::Error) { HouseInference::Gateway.new(agent: @agent, input: @input).call { |_| } }
      end
      spent += BigDecimal('0.75')
      assert_equal spent, @grant.spent, "#{status} #{body[0, 30]} must keep the conservative charge"
    end
    assert_not @grant.house_inference_calls.where(status: 'pending').exists?
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
