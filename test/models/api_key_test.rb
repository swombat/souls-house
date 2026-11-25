require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase

  setup do
    @user = users(:confirmed_user)
  end

  test "generates key with correct prefix" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    assert key.raw_token.start_with?("hx_")
    assert_equal @user.default_account, key.account
  end

  test "generates key with correct length" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    # hx_ (3) + 48 hex chars = 51 total
    assert_equal 51, key.raw_token.length
  end

  test "authenticates valid token" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    assert_equal key, ApiKey.authenticate(raw_token)
  end

  test "can be scoped to a single agent" do
    agent = agents(:research_assistant)
    key = ApiKey.generate_for(@user, name: "Agent Key", agent: agent)

    assert_equal agent, key.agent
    assert_equal agent.account, key.account
    assert_equal key, ApiKey.authenticate(key.raw_token)
  end

  test "rejects invalid token" do
    assert_nil ApiKey.authenticate("invalid")
    assert_nil ApiKey.authenticate(nil)
    assert_nil ApiKey.authenticate("")
  end

  test "pausing a hosted resident does not disable its key" do
    agent = agents(:research_assistant)
    agent.update_columns(active: true, paused: true)
    key = ApiKey.generate_for(@user, name: "Paused resident", agent: agent)

    assert_equal key, ApiKey.authenticate(key.raw_token)
  end

  test "raw_token only available immediately after creation" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    assert key.raw_token.present?

    reloaded = ApiKey.find(key.id)
    assert_raises(NoMethodError) { reloaded.raw_token }
  end

  test "stores SHA256 digest not raw token" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    assert_equal Digest::SHA256.hexdigest(raw_token), key.token_digest
  end

  test "stores token prefix for display" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    assert_equal raw_token[0, 8], key.token_prefix
    assert_equal "#{raw_token[0, 8]}...", key.display_prefix
  end

  test "validates name presence" do
    key = ApiKey.new(user: @user, token_digest: "abc", token_prefix: "hx_12345")
    assert_not key.valid?
    assert_includes key.errors[:name], "can't be blank"
  end

  test "validates name length" do
    key = ApiKey.new(user: @user, name: "a" * 101, token_digest: "abc", token_prefix: "hx_12345")
    assert_not key.valid?
    assert key.errors[:name].any? { |e| e.include?("too long") }
  end

  test "validates token_digest uniqueness" do
    key1 = ApiKey.generate_for(@user, name: "Key 1")

    key2 = ApiKey.new(user: @user, name: "Key 2", token_digest: key1.token_digest, token_prefix: "hx_other")
    assert_not key2.valid?
    assert_includes key2.errors[:token_digest], "has already been taken"
  end

  test "touch_usage updates last_used fields" do
    key = ApiKey.generate_for(@user, name: "Test Key")

    assert_nil key.last_used_at
    assert_nil key.last_used_ip

    key.touch_usage!("192.168.1.1")
    key.reload

    assert_not_nil key.last_used_at
    assert_equal "192.168.1.1", key.last_used_ip
  end

  test "by_creation scope orders by created_at desc" do
    key1 = ApiKey.generate_for(@user, name: "First")
    key2 = ApiKey.generate_for(@user, name: "Second")

    keys = @user.api_keys.by_creation
    assert_equal [ key2.id, key1.id ], keys.pluck(:id)
  end

  test "api_keys association has dependent destroy" do
    # Verify the association is configured with dependent: :destroy
    association = User.reflect_on_association(:api_keys)
    assert_equal :destroy, association.options[:dependent]
  end

end
