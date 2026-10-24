require "test_helper"
require "support/field_tweet_helpers"

class FieldTweetFundingTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include FieldTweetHelpers

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Funding #{SecureRandom.hex(4)}", account_type: "team")
    @other = Account.create!(name: "Funding isolation #{SecureRandom.hex(4)}", account_type: "team")
    @stream = "FieldTweetStream:#{@account.to_param}"
    @other_stream = "FieldTweetStream:#{@other.to_param}"
    clear_enqueued_jobs
  end

  teardown do
    [ @account, @other ].each { |account| account.reload.destroy! }
  end

  test "no-source connection create revoke reconnect and destroy are content-free" do
    connection = nil
    assert_marker { connection = connect_twitterapi_io(@account, "SECRET-KEY") }
    assert_equal "own", FieldTweets.funding_for(@account)
    assert_marker { connection.update!(status: "revoked") }
    assert_nil FieldTweets.funding_for(@account)
    assert_marker { connection.update!(status: "connected") }
    assert_marker { connection.destroy! }
    assert_nil FieldTweets.funding_for(@account)
  end

  test "feature-off funding discovery still works without a source" do
    setting = Setting.instance
    enabled = setting.field_tweets_enabled
    setting.update_columns(field_tweets_enabled: false)
    assert_marker { connect_twitterapi_io(@account) }
    assert_marker { @account.update!(field_tweets_house_key: true) }
  ensure
    setting&.update_columns(field_tweets_enabled: enabled)
  end

  test "unconnected to unconnected changes remain quiet and becoming eligible signals" do
    connection = @account.service_connections.new(provider: "twitterapi_io", management_scope: "account_managed",
      status: "revoked", credential_kind: "api_key", connected_by_user: users(:user_1))
    assert_no_broadcasts(@stream) do
      connection.save!
      connection.update!(status: "error")
      connection.update!(credential_payload: '{"api_key":"NOT-CONNECTED"}')
    end
    assert_marker { connection.update!(status: "connected") }
    assert_marker { connection.update!(status: "revoked") }
    assert_no_broadcasts(@stream) { connection.destroy! }
  end

  test "paused sources discover funding without restarting" do
    source = @account.create_field_tweet_source!(handle: "danielt", state: "paused", state_reason: "A person's pause")
    assert_marker { connect_twitterapi_io(@account) }
    assert_equal [ "paused", "A person's pause" ], [ source.reload.state, source.state_reason ]
    assert_marker { @account.update!(field_tweets_house_key: true) }
    assert_marker { @account.update!(field_tweets_house_key: false) }
    assert_equal "paused", source.reload.state
  end

  test "house grants work without a source and unrelated account writes are quiet" do
    assert_marker { @account.update!(field_tweets_house_key: true) }
    assert_equal "house", FieldTweets.funding_for(@account)
    assert_no_broadcasts(@stream) do
      @account.update!(field_tweets_house_key: true, name: "Different name")
      @account.touch
    end
    assert_marker { @account.update!(field_tweets_house_key: false) }
    assert_nil FieldTweets.funding_for(@account)
  end

  test "moving eligible connection signals old and new accounts exactly once" do
    connection = connect_twitterapi_io(@account)
    messages = capture_broadcasts(@other_stream) do
      assert_equal marker, capture_broadcasts(@stream) { connection.update!(account: @other) }
    end
    assert_equal marker, messages
    assert_nil FieldTweets.funding_for(@account)
    assert_equal "own", FieldTweets.funding_for(@other)
  end

  test "old and new provider and scope determine discovery" do
    connection = connect_twitterapi_io(@account)
    assert_marker { connection.update!(provider: "google_workspace", management_scope: "personal") }
    assert_marker { connection.update!(provider: "twitterapi_io", management_scope: "account_managed") }
    # TwitterAPI.io deliberately supports only account-managed connections.
    # Model callbacks must still handle legacy/internal ineligible rows.
    assert_marker { connection.update_attribute!(:management_scope, "personal") }
    assert_no_broadcasts(@stream) do
      connection.update_attribute!(:status, "revoked")
      connection.update_attribute!(:status, "connected")
    end
    assert_marker { connection.update_attribute!(:management_scope, "account_managed") }
  end

  test "ineligible connection creation reassignment and destruction are quiet" do
    assert_no_broadcasts(@stream) do
      assert_no_broadcasts(@other_stream) do
        connection = @account.service_connections.new(provider: "twitterapi_io", management_scope: "personal",
          status: "connected", credential_kind: "api_key", connected_by_user: users(:user_1))
        connection.save!(validate: false)
        connection.update_attribute!(:account, @other)
        connection.destroy!
        connection = @account.service_connections.create!(provider: "google_workspace", management_scope: "personal",
          status: "connected", credential_kind: "oauth", connected_by_user: users(:user_1))
        connection.update!(status: "revoked")
        connection.destroy!
      end
    end
  end

  test "payload rotation is not discovery but still restarts an attention source" do
    connection = connect_twitterapi_io(@account)
    assert_no_broadcasts(@stream) { connection.update!(credential_payload: '{"api_key":"ROTATED"}') }
    source = @account.create_field_tweet_source!(handle: "danielt", state: "needs_attention", failure_count: 8,
      state_reason: "Bad key")
    assert_marker { connection.update!(credential_payload: '{"api_key":"ROTATED-AGAIN"}') }
    assert_equal [ "active", 0, nil ], [ source.reload.state, source.failure_count, source.state_reason ]
    source.pause!("Paused by a person")
    assert_no_broadcasts(@stream) { connection.update!(credential_payload: '{"api_key":"PAUSED-ROTATION"}') }
    assert_equal "paused", source.reload.state
  end

  test "labels provisioning metadata comms bookkeeping and per-call spend are not discovery" do
    connection = connect_twitterapi_io(@account)
    assert_no_broadcasts(@stream) do
      connection.update!(label: "Renamed", enabled_for_new_agents: true, freely_provisionable: true,
        credential_metadata: { unread: 12 }, connector_state: { availability: { state: "busy" } })
      connection.touch
      connection.save!
      call = @account.field_tweet_calls.create!(funding: "own", status: "reserved", charge_usd: "0.001")
      call.update!(status: "settled", charge_usd: "0.00015")
      call.destroy!
    end
  end

  test "later hidden writes cannot erase funding and grant changes and markers coalesce" do
    assert_marker do
      Account.transaction do
        assert_no_broadcasts(@stream) do
          connect_twitterapi_io(@account).update!(label: "Hidden", credential_metadata: { unread: 3 })
          @account.update!(field_tweets_house_key: true)
          @account.touch
          @account.reload.save!
        end
      end
    end
  end

  test "outer and savepoint rollbacks discard funding grant and restart callbacks" do
    source = @account.create_field_tweet_source!(handle: "danielt", state: "needs_attention", failure_count: 8)
    assert_no_broadcasts(@stream) do
      Account.transaction do
        connect_twitterapi_io(@account)
        @account.update!(field_tweets_house_key: true)
        raise ActiveRecord::Rollback
      end
      Account.transaction do
        Account.transaction(requires_new: true) do
          connect_twitterapi_io(@account)
          @account.reload.update!(field_tweets_house_key: true)
          raise ActiveRecord::Rollback
        end
        @account.reload.touch
      end
    end
    assert_nil FieldTweets.funding_for(@account.reload)
    assert_equal [ "needs_attention", 8 ], [ source.reload.state, source.failure_count ]
    assert_marker { @account.update!(field_tweets_house_key: true) }
  end

  test "rolled-back reassignment and destruction leave both accounts quiet" do
    connection = connect_twitterapi_io(@account)
    assert_no_broadcasts(@stream) do
      assert_no_broadcasts(@other_stream) do
        ServiceConnection.transaction do
          connection.update!(account: @other)
          connection.destroy!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal @account.id, connection.reload.account_id
    assert_marker { connection.destroy! }
  end

  private

  def marker = [ { "action" => "refresh" } ]

  def assert_marker(&block)
    assert_no_broadcasts(@other_stream) { assert_equal marker, capture_broadcasts(@stream, &block) }
  end

end
