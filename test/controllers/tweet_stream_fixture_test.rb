require "test_helper"

class TweetStreamFixtureTest < ActionDispatch::IntegrationTest

  test "browser fixture mutates only synthetic account source state" do
    account = Account.create!(name: "E2E Tweet source fixture", account_type: :team)
    account.add_user!(users(:user_1), role: "owner", skip_confirmation: true)
    %w[enable create advance bookkeeping].each do |operation|
      post "/test/e2e/tweet_stream_fixture", params: { account_id: account.id, operation: }, as: :json
      assert_response :success
    end
    assert_equal "example", account.reload.field_tweet_source.handle
    assert account.field_tweet_source.last_success_at
    assert_equal 2, account.field_tweet_source.failure_count
  end

  test "browser fixture refuses non-synthetic accounts" do
    post "/test/e2e/tweet_stream_fixture",
      params: { account_id: accounts(:personal_account).id, operation: "create" }, as: :json
    assert_response :not_found
  end

  test "funding fixture supports an initially unfunded account without a source" do
    account = Account.create!(name: "E2E Tweet funding fixture", account_type: :team)
    account.add_user!(users(:user_1), role: "owner", skip_confirmation: true)
    %w[enable_unfunded fund funding_bookkeeping unfund].each do |operation|
      post "/test/e2e/tweet_stream_fixture", params: { account_id: account.id, operation: }, as: :json
      assert_response :success
    end
    assert_nil account.reload.field_tweet_source
    connection = account.service_connections.find_by!(label: "Synthetic tweet funding")
    assert_equal "revoked", connection.status
    assert_equal 7, connection.comms_event_seq
    assert_equal "synthetic-no-vendor-access", connection.credential_payload_hash.fetch("api_key")
  end

end
