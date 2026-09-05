require "test_helper"

class UtilityInferenceTest < ActiveSupport::TestCase

  test "titles use only the account OpenRouter credential and bounded output" do
    account = accounts(:personal_account)
    account.update!(use_system_ai_credentials: false, openrouter_api_key: "account-key")
    captured = {}
    client = Object.new
    client.define_singleton_method(:chat) do |parameters:|
      captured[:parameters] = parameters
      { "choices" => [ { "message" => { "content" => "A new conversation" } } ] }
    end
    OpenAI::Client.stub :new, ->(**options) { captured[:options] = options; client } do
      assert_equal "A new conversation", UtilityInference.title(account: account, system: "Title", user: "Hello")
    end
    assert_equal "account-key", captured[:options][:access_token]
    assert_equal false, captured[:options][:log_errors]
    assert_equal 20, captured[:options][:request_timeout]
    assert_equal "https://openrouter.ai/api/v1", captured[:options][:uri_base]
    assert_equal "google/gemini-2.5-flash", captured[:parameters][:model]
    assert_equal 1_000, captured[:parameters][:max_tokens]
    assert_equal({ effort: "none" }, captured[:parameters][:reasoning])
  end

  test "missing account credentials never borrow system credentials without permission" do
    account = accounts(:personal_account)
    account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    Account.stub :system_ai_api_key, ->(*) { flunk "System fallback not permitted" } do
      OpenAI::Client.stub :new, ->(*) { flunk "No request expected" } do
        assert_nil UtilityInference.title(account: account, system: "Title", user: "Hello")
      end
    end
  end

  test "allowed account fallback uses system key" do
    account = accounts(:personal_account)
    account.update!(use_system_ai_credentials: true, openrouter_api_key: nil)
    Account.stub :system_ai_api_key, ->(provider) { assert_equal :openrouter, provider; "system-key" } do
      assert_equal "system-key", account.ai_api_key(:openrouter)
    end
  end

  test "moderation uses the site OpenAI credential and explicit model" do
    client = Minitest::Mock.new
    client.expect :moderations, { "results" => [ { "category_scores" => { "hate" => 0.01 } } ] },
      parameters: { model: "omni-moderation-latest", input: "Hello" }
    Account.stub :system_ai_api_key, ->(provider) { assert_equal :openai, provider; "site-key" } do
      OpenAI::Client.stub :new, ->(**options) {
        assert_equal "site-key", options[:access_token]
        assert_equal "https://api.openai.com/v1", options[:uri_base]
        client
      } do
        assert_equal({ "hate" => 0.01 }, UtilityInference.moderate("Hello"))
      end
    end
    client.verify
  end

  test "empty and invalid moderation results never mark messages moderated" do
    chat = Chat.create!(account: accounts(:personal_account), title: "Utility test")
    message = chat.messages.create!(role: "assistant", content: "Hello")
    [ {}, { "results" => [] }, { "results" => [ { "category_scores" => {} } ] },
      { "results" => [ { "category_scores" => { "hate" => "invalid" } } ] } ].each do |response|
      client = Object.new
      client.define_singleton_method(:moderations) { |**| response }
      Account.stub :system_ai_api_key, "key" do
        OpenAI::Client.stub :new, client do
          assert_raises(UtilityInference::InvalidResponse) { ModerateMessageJob.perform_now(message) }
        end
      end
      assert_nil message.reload.moderated_at
    end
  end

  test "input limit rejects before opening a client" do
    OpenAI::Client.stub :new, ->(*) { flunk "No request expected" } do
      assert_raises(UtilityInference::InputTooLong) { UtilityInference.moderate("x" * 32_001) }
    end
  end

  test "placeholder credentials are not passed to an HTTP client" do
    Account.stub :system_ai_api_key, "<OPENAI_API_KEY>" do
      OpenAI::Client.stub :new, ->(*) { flunk "No request expected" } do
        assert_raises(UtilityInference::MissingCredentials) { UtilityInference.moderate("Hello") }
      end
    end
  end

  test "empty utility responses raise instead of fabricating content" do
    client = Object.new
    client.define_singleton_method(:chat) { |**| { "choices" => [] } }
    Account.stub :system_ai_api_key, "site-key" do
      OpenAI::Client.stub :new, client do
        assert_raises(UtilityInference::InvalidResponse) do
          UtilityInference.classify(model: SafeguardResponseCheck::CLASSIFIER_MODEL, prompt: "Candidate")
        end
      end
    end
  end

  test "classifier uses site OpenRouter key and leaves verdict parsing to the caller" do
    client = Minitest::Mock.new
    client.expect :chat, { "choices" => [ { "message" => { "content" => "PASS\nSpecific reply" } } ] },
      parameters: { model: SafeguardResponseCheck::CLASSIFIER_MODEL,
        messages: [ { role: "user", content: "Candidate" } ],
        max_tokens: 1_000, reasoning: { effort: "none" } }
    Account.stub :system_ai_api_key, ->(provider) { assert_equal :openrouter, provider; "site-key" } do
      OpenAI::Client.stub :new, client do
        assert_equal "PASS\nSpecific reply",
          UtilityInference.classify(model: SafeguardResponseCheck::CLASSIFIER_MODEL, prompt: "Candidate")
      end
    end
    client.verify
  end

end
