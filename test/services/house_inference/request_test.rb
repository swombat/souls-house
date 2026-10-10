require 'test_helper'

class HouseInference::RequestTest < ActiveSupport::TestCase

  setup do
    @offering = HouseInference::Offering.find(HouseInference::Offering::DEEPSEEK_MODEL_ID)
    @input = { 'model' => HouseInference::Offering::DEEPSEEK_MODEL_ID, 'stream' => true,
      'messages' => [ { 'role' => 'user', 'content' => 'Hello' } ] }
  end

  test 'input context is independently bounded rather than trusting provider defaults' do
    @input['messages'][0]['content'] = 'x' * 1_048_576
    assert_raises(HouseInference::Error) { HouseInference::Request.build(@input, @offering) }
  end

  test 'pins route price and output with no provider fallback' do
    body = HouseInference::Request.build(@input.merge('max_tokens' => 999_999), @offering)
    assert_equal [ 'fireworks/us' ], body.dig('provider', 'only')
    assert_equal false, body.dig('provider', 'allow_fallbacks')
    assert_equal @offering[:max_price], body.dig('provider', 'max_price')
    assert_equal 16_384, body['max_tokens']
    assert_equal 'deepseek/deepseek-v4.1-flash', body['model']
  end

  test 'parallel_tool_calls is accepted from the runtime but never sent upstream' do
    tool = { 'type' => 'function', 'function' => { 'name' => 'noop', 'parameters' => { 'type' => 'object', 'properties' => {} } } }
    [ true, false ].each do |value|
      body = HouseInference::Request.build(@input.merge('tools' => [ tool ], 'parallel_tool_calls' => value), @offering)
      assert_not body.key?('parallel_tool_calls'), "parallel_tool_calls=#{value} must not reach OpenRouter"
      assert_equal true, body.dig('provider', 'require_parameters')
      assert_equal [ tool ], body['tools']
    end
  end

  test 'Haiku is pinned to Anthropic with its own caps' do
    offering = HouseInference::Offering.find(HouseInference::Offering::HAIKU_MODEL_ID)
    body = HouseInference::Request.build(@input.merge('model' => HouseInference::Offering::HAIKU_MODEL_ID, 'max_tokens' => 999_999), offering)
    assert_equal 'anthropic/claude-haiku-5.5', body['model']
    assert_equal [ 'anthropic' ], body.dig('provider', 'only')
    assert_equal false, body.dig('provider', 'allow_fallbacks')
    assert_equal({ prompt: 0.6, completion: 3.0 }, body.dig('provider', 'max_price'))
    assert_equal 16_384, body['max_tokens']
  end

  test 'Haiku input is bounded below its million-token context' do
    offering = HouseInference::Offering.find(HouseInference::Offering::HAIKU_MODEL_ID)
    @input['messages'][0]['content'] = 'x' * 1_000_000
    assert_raises(HouseInference::Error) { HouseInference::Request.build(@input, offering) }
  end

  test 'paid extras arbitrary routes and multimodal inputs are refused' do
    %w[provider models plugins web_search_options service_tier n transforms].each do |key|
      assert_raises(HouseInference::Error) { HouseInference::Request.build(@input.merge(key => {}), @offering) }
    end
    @input['messages'][0]['content'] = [ { 'type' => 'image_url', 'image_url' => { 'url' => 'https://example.com/private' } } ]
    assert_raises(HouseInference::Error) { HouseInference::Request.build(@input, @offering) }
  end

  test 'function calls and reasoning metadata survive' do
    @input['messages'] << { 'role' => 'assistant', 'content' => nil, 'reasoning_details' => [ { 'type' => 'reasoning.text', 'text' => 'thinking' } ],
      'tool_calls' => [ { 'id' => 'call1', 'type' => 'function', 'function' => { 'name' => 'tool', 'arguments' => '{}' } } ] }
    @input['messages'] << { 'role' => 'tool', 'tool_call_id' => 'call1', 'content' => 'done' }
    @input['tools'] = [ { 'type' => 'function', 'function' => { 'name' => 'tool', 'parameters' => { 'type' => 'object' } } } ]
    body = HouseInference::Request.build(@input, @offering)
    assert_equal @input['messages'], body['messages']
    assert_equal @input['tools'], body['tools']
  end

end
