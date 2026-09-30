require 'test_helper'

class Api::V1::HouseInferenceControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:user_1)
    @agent.update!(model_id: HouseInference::Offering::MODEL_ID)
    HouseInferenceGrant.assign!(@agent, @user)
    @key = ApiKey.generate_for(@user, name: 'house synthetic', agent: @agent)
    @headers = { 'Authorization' => "Bearer #{@key.raw_token}", 'SERVER_PROTOCOL' => 'HTTP/1.1' }
    @input = { model: @agent.model_id, stream: true, messages: [ { role: 'user', content: 'synthetic' } ] }
    @path = '/api/v1/house_inference/chat/completions'
  end

  test 'only resident bearer credentials can discover the funded model' do
    get '/api/v1/house_inference/models', headers: @headers
    assert_response :success
    assert_equal [ @agent.model_id ], response.parsed_body['data'].pluck('id')
    human_key = ApiKey.generate_for(@user, name: 'human')
    get '/api/v1/house_inference/models', headers: { 'Authorization' => "Bearer #{human_key.raw_token}" }
    assert_response :forbidden
    post @path, params: @input, as: :json
    assert_response :unauthorized
  end

  test 'another resident cannot spend the sponsor allowance' do
    peer_key = ApiKey.generate_for(@user, name: 'peer', agent: agents(:code_reviewer))
    post @path, params: @input, headers: { 'Authorization' => "Bearer #{peer_key.raw_token}" }, as: :json
    assert_response :forbidden
    assert_equal 0, HouseInferenceCall.count
  end

  test 'unconfigured route and exhaustion are not credential setup errors' do
    HouseInference::Offering.stub(:configured?, false) do
      post @path, params: @input, headers: @headers, as: :json
      assert_response :service_unavailable
      assert_equal 'house_inference_unavailable', response.parsed_body.dig('error', 'code')
    end
    grant = HouseInferenceGrant.find_by!(agent: @agent)
    grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: 'fireworks/us', charge_usd: 10, status: 'settled')
    HouseInference::Offering.stub(:configured?, true) do
      post @path, params: @input, headers: @headers, as: :json
      assert_response :payment_required
      assert_equal 'house_allowance_exhausted', response.parsed_body.dig('error', 'code')
    end
  end

  test 'unexpected gateway failures are not mistaken for empty successful responses' do
    HouseInference::Gateway.stub(:new, ->(**) { raise RuntimeError, "synthetic failure" }) do
      post @path, params: @input, headers: @headers, as: :json
    end
    assert_response :service_unavailable
    assert_equal 'house_inference_unavailable', response.parsed_body.dig('error', 'code')
    assert_not_includes response.body, 'synthetic failure'
  end

  test 'successful response uses SSE and preserves tool call frames' do
    gateway = Object.new
    gateway.define_singleton_method(:call) do |&block|
      block.call("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"test\",\"arguments\":\"{}\"}}]}}]}\n\n")
      block.call("data: [DONE]\n\n")
    end
    HouseInference::Gateway.stub(:new, ->(**) { gateway }) do
      post @path, params: @input, headers: @headers, as: :json
    end
    assert_response :success
    assert_equal 'text/event-stream', response.media_type
    assert_includes response.body, 'tool_calls'
    assert_includes response.body, '[DONE]'
  end

end
