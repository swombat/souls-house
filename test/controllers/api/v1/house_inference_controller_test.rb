require 'test_helper'

class Api::V1::HouseInferenceControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:user_1)
    @agent.update!(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID)
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

  test 'model discovery reports the selected offering’s own context window' do
    get '/api/v1/house_inference/models', headers: @headers
    assert_equal [ 1_048_576 ], response.parsed_body['data'].pluck('context_length')
    @agent.update!(model_id: HouseInference::Offering::HAIKU_MODEL_ID)
    get '/api/v1/house_inference/models', headers: @headers
    assert_equal [ [ 'house/claude-haiku-5.5', 1_000_000 ] ], response.parsed_body['data'].map { |m| [ m['id'], m['context_length'] ] }
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

  test 'a refused call is recorded on the run named in the header and on no other run' do
    # Two concurrent runs of the same resident, and one of another resident.
    refused = @agent.agent_runtime_interactions.create!(trigger_kind: 'wake', requested_by: 'house', started_at: 2.minutes.ago)
    sibling = @agent.agent_runtime_interactions.create!(trigger_kind: 'conversation', requested_by: 'house', started_at: 1.minute.ago)
    finished = @agent.agent_runtime_interactions.create!(trigger_kind: 'wake', requested_by: 'house',
      started_at: 1.hour.ago, finished_at: 50.minutes.ago)
    foreign = agents(:code_reviewer).agent_runtime_interactions.create!(trigger_kind: 'wake', requested_by: 'house', started_at: 1.minute.ago)
    grant = HouseInferenceGrant.find_by!(agent: @agent)
    grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: 'fireworks/us', charge_usd: 10, status: 'settled')

    HouseInference::Offering.stub(:configured?, true) do
      [ foreign.id, finished.id, 'not-a-run', nil ].each do |header|
        post @path, params: @input, headers: @headers.merge('X-Soulshouse-Run' => header.to_s), as: :json
        assert_response :payment_required
      end
      assert_nil foreign.reload.inference_refusal, 'another resident’s run is never marked'
      assert_nil finished.reload.inference_refusal, 'a finished run did not make this call'
      assert_nil refused.reload.inference_refusal
      assert_nil sibling.reload.inference_refusal

      post @path, params: @input, headers: @headers.merge('X-Soulshouse-Run' => refused.id.to_s), as: :json
      assert_response :payment_required
    end
    assert_equal 'house_allowance_exhausted', refused.reload.inference_refusal
    assert_nil sibling.reload.inference_refusal, 'a concurrent run of the same resident does not borrow the refusal'
  end

  test 'the house provider refusing a call is recorded too, and never overwrites an earlier refusal' do
    run = @agent.agent_runtime_interactions.create!(trigger_kind: 'wake', requested_by: 'house', started_at: 1.minute.ago)
    refused = HouseInference::Error.new('refused', code: 'house_provider_refused', status: 502,
      reason: 'Anthropic code 400 invalid_request_error: max_tokens: 64001 > 64000')
    HouseInference::Gateway.stub(:new, ->(**) { raise refused }) do
      post @path, params: @input, headers: @headers.merge('X-Soulshouse-Run' => run.id.to_s), as: :json
    end
    assert_response :bad_gateway
    assert_equal 'house_provider_refused', run.reload.inference_refusal
    assert_equal refused.reason, run.inference_refusal_reason
    refute_includes response.body, 'max_tokens', 'the reason is for the run record, not the resident'
    run.update!(finished_at: Time.current, execution_state: 'failed')
    assert_equal "the house's model provider refused a request it made (reason: #{refused.reason})",
      run.failure_reason

    run.update_columns(inference_refusal: 'house_allowance_exhausted', inference_refusal_reason: nil, finished_at: nil)
    HouseInference::Gateway.stub(:new, ->(**) { raise refused }) do
      post @path, params: @input, headers: @headers.merge('X-Soulshouse-Run' => run.id.to_s), as: :json
    end
    assert_equal 'house_allowance_exhausted', run.reload.inference_refusal
    assert_nil run.inference_refusal_reason
  end

  test 'a refusal that is not about the allowance is not recorded' do
    run = @agent.agent_runtime_interactions.create!(trigger_kind: 'wake', requested_by: 'house', started_at: 1.minute.ago)
    HouseInference::Offering.stub(:configured?, false) do
      post @path, params: @input, headers: @headers.merge('X-Soulshouse-Run' => run.id.to_s), as: :json
    end
    assert_response :service_unavailable
    assert_nil run.reload.inference_refusal
  end

  test 'a Haiku request ending in an assistant message is refused locally, unreserved, with the reason on the run (#725)' do
    @agent.update!(model_id: HouseInference::Offering::HAIKU_MODEL_ID)
    run = @agent.agent_runtime_interactions.create!(trigger_kind: 'wake', requested_by: 'house', started_at: 1.minute.ago)
    input = @input.merge(model: @agent.model_id, messages: @input[:messages] + [ { role: 'assistant', content: 'synthetic half' } ])
    assert_no_difference -> { HouseInferenceCall.count } do
      HouseInference::Offering.stub(:configured?, true) do
        post @path, params: input, headers: @headers.merge('X-Soulshouse-Run' => run.id.to_s), as: :json
      end
    end
    assert_response :bad_request
    assert_equal 'house_provider_refused', response.parsed_body.dig('error', 'code')
    refute_includes response.body, 'prefill', 'the reason is for the run record, not the resident'
    assert_equal 'house_provider_refused', run.reload.inference_refusal
    assert_equal HouseInference::Request::PREFILL_REASON, run.inference_refusal_reason
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


  test 'a paid fallback refusal is recorded on the fallback run, and the fallback model is listed only when on (#690)' do
    @agent.account.update_columns(openrouter_api_key: 'sk-or-own')
    chat = @agent.account.chats.create!(title: 'Fallback', manual_responses: true, agents: [ @agent ])
    ResidentFallbackPolicy.create!(agent: @agent, enabled: true, model_id: 'anthropic/claude-sonnet-5', cap_usd: 0.01,
      enabled_by_user: @user, enabled_at: Time.current)
    get '/api/v1/house_inference/models', headers: @headers
    assert_equal [ @agent.model_id ], response.parsed_body['data'].pluck('id'), 'switch off: not listed'

    Setting.instance.update!(paid_fallback_enabled: true)
    get '/api/v1/house_inference/models', headers: @headers
    assert_equal [ @agent.model_id, 'fallback/anthropic/claude-sonnet-5' ], response.parsed_body['data'].pluck('id')

    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat)
    ResidentFallbackTurn.create!(agent: @agent, chat: chat, fallback_interaction: run, primary_provider: 'openai',
      primary_model: 'openai/gpt-5', fallback_model_id: 'anthropic/claude-sonnet-5', upstream_model: 'anthropic/claude-sonnet-5')
    post @path, params: @input.merge(model: 'fallback/anthropic/claude-sonnet-5', stream: false, max_tokens: 32_000),
      headers: @headers.merge('X-Soulshouse-Run' => run.id.to_s), as: :json
    assert_response :payment_required
    assert_equal 'fallback_cap_reached', response.parsed_body.dig('error', 'code')
    assert_equal 'fallback_cap_reached', run.reload.inference_refusal
    assert_equal 0, ResidentFallbackCall.count
  end

end
