require "test_helper"

class ResolvesProviderTest < ActiveSupport::TestCase

  test "Kimi Code always retains its subscription route regardless of key availability" do
    %w[k3.1-pro k3.1-pro-highspeed k3 k3-256k kimi-for-coding kimi-for-coding-highspeed].each do |id|
      [ true, false ].each do |available|
        ResolvesProvider.stub(:api_key_available?, available) do
          assert_equal({ provider: :kimi, model_id: id }, ResolvesProvider.resolve_provider("kimi-code/#{id}"))
        end
      end
    end
  end

  test "unknown Kimi Code IDs are refused instead of sent to OpenRouter" do
    %w[kimi-code/not-a-model kimi-code/kimi-k3.1-pro kimi-code/].each do |id|
      error = assert_raises(ArgumentError) { ResolvesProvider.resolve_provider(id) }
      assert_match(/Unknown Kimi Code subscription model/, error.message)
    end
  end

  test "Moonshot catalogue selections stay on OpenRouter even with keys" do
    ResolvesProvider.stub(:api_key_available?, true) do
      Chat::MODELS.select { |model| model[:model_id].start_with?("moonshotai/") }.each do |model|
        id = model[:model_id]
        assert_equal({ provider: :openrouter, model_id: id }, ResolvesProvider.resolve_provider(id))
      end
    end
  end

  test "Kimi availability reads the account Moonshot key slot" do
    account = Minitest::Mock.new
    account.expect(:ai_api_key, "synthetic-subscription-key", [ :moonshot ])
    assert ResolvesProvider.api_key_available?(:kimi, account: account)
    account.verify
  end

  test "missing and placeholder Moonshot keys do not make Kimi available" do
    [ nil, "", "<configure-key>" ].each do |key|
      account = Minitest::Mock.new
      account.expect(:ai_api_key, key, [ :moonshot ])
      refute ResolvesProvider.api_key_available?("kimi", account: account)
      account.verify
    end
  end

  test "Kimi system availability uses the existing Moonshot key slot" do
    provider_read = nil
    Account.stub(:system_ai_api_key, ->(provider) { provider_read = provider; "synthetic-key" }) do
      assert ResolvesProvider.api_key_available?(:kimi)
    end
    assert_equal :moonshot, provider_read
  end

end
