require "test_helper"

class UtilityDecisionsTest < ActiveSupport::TestCase

  setup do
    @questions = { "daniel" => { type: "noul", instructions: "Reply expected?", criteria: { "true" => "yes", "false" => "no" } } }
  end

  test "typed decisions use the dedicated endpoint and validate probabilities" do
    request = Struct.new(:headers, :options, :body).new({}, Struct.new(:timeout, :open_timeout).new, nil)
    response = Struct.new(:status, :body) { def success? = true }.new(200, { answers: { daniel: { type: "noul", noul: 0.92 } } }.to_json)
    transport = ->(url, &block) {
      assert_equal "https://openrouter.ai/api/alpha/decisions", url
      block.call(request)
      assert_equal "Bearer synthetic-key", request.headers["Authorization"]
      assert_equal "typesafe/jev-1.13", JSON.parse(request.body)["model"]
      assert_equal 20, request.options.timeout
      response
    }
    Account.stub :system_ai_api_key, "synthetic-key" do
      Faraday.stub :post, transport do
        assert_equal({ "daniel" => 0.92 }, UtilityInference.decide(state: { text: "Hello" }, questions: @questions))
      end
    end
  end

  test "rejects missing extra malformed and nonfinite answers" do
    [
      {}, { "wrong" => { type: "noul", noul: 0.9 } },
      { "daniel" => { type: "noul", noul: "0.9" } },
      { "daniel" => { type: "choice", noul: 0.9 } },
      { "daniel" => { type: "noul", noul: 1.1 } }
    ].each do |answers|
      response = Struct.new(:status, :body) { def success? = true }.new(200, { answers: answers }.to_json)
      Account.stub :system_ai_api_key, "synthetic-key" do
        Faraday.stub :post, ->(*) { response } do
          assert_raises(UtilityInference::InvalidResponse) { UtilityInference.decide(state: {}, questions: @questions) }
        end
      end
    end
  end

  test "transport errors and invalid input cannot disclose text or keys" do
    Account.stub :system_ai_api_key, "synthetic-secret" do
      Faraday.stub :post, ->(*) { raise Faraday::TimeoutError, "synthetic-secret private text" } do
        error = assert_raises(UtilityInference::InvalidResponse) { UtilityInference.decide(state: {}, questions: @questions) }
        assert_not_includes error.message, "synthetic-secret"
        assert_not_includes error.message, "private text"
      end
    end
    assert_raises(UtilityInference::InputTooLong) do
      UtilityInference.decide(state: { text: "a" * 32_001 }, questions: @questions)
    end
  end

  test "non-object provider JSON is a safe invalid response" do
    response = Struct.new(:status, :body) { def success? = true }.new(200, '"private source text"')
    Account.stub :system_ai_api_key, "synthetic-key" do
      Faraday.stub :post, ->(*) { response } do
        error = assert_raises(UtilityInference::InvalidResponse) { UtilityInference.decide(state: {}, questions: @questions) }
        assert_not_includes error.message, "private source text"
      end
    end
  end

end
