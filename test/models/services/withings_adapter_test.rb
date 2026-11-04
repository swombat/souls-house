require "test_helper"

class Services::WithingsAdapterTest < ActiveSupport::TestCase

  setup do
    @definition = Services::Definition.fetch("withings")
    @adapter = Services::WithingsAdapter.new(@definition)
    @attempt, = ServiceAuthorizationAttempt.begin!(
      account: accounts(:personal_account),
      user: users(:user_1),
      provider: "withings",
      management_scope: "personal",
      access_profile: "health_read",
      return_path: "/return"
    )
  end

  test "builds a Withings authorization URL with comma-separated scopes" do
    url = @adapter.stub(:client_id, "test-withings-client") do
      @adapter.authorization_url(
        @attempt,
        state: "state-value",
        redirect_uri: "https://example.test/service_authorizations/callback"
      )
    end
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "account.withings.com", URI(url).host
    assert_equal "test-withings-client", query["client_id"]
    assert_equal "state-value", query["state"]
    assert_equal "https://example.test/service_authorizations/callback", query["redirect_uri"]
    assert_equal "user.info,user.metrics,user.activity", query["scope"]
  end

  test "exchanges an authorization code through action=requesttoken and unwraps the body" do
    posted = nil
    response = withings_response(status: 0, body: {
      "userid" => 363, "access_token" => "w-access", "refresh_token" => "w-refresh",
      "expires_in" => 10_800, "scope" => "user.info,user.metrics,user.activity", "token_type" => "Bearer"
    })

    with_credentials do
      Net::HTTP.stub(:post_form, ->(uri, params) { posted = [ uri, params ]; response }) do
        result = @adapter.exchange_code(
          code: "provider-code",
          attempt: @attempt,
          redirect_uri: "https://example.test/service_authorizations/callback"
        )

        assert_equal "363", result[:external_subject_id]
        assert_equal users(:user_1).email_address, result[:external_identity]
        assert_equal "w-refresh", result.dig(:credential_payload, "refresh_token")
        assert_equal %w[user.info user.metrics user.activity], result.dig(:credential_metadata, "granted_scopes")
        assert_in_delta 3.hours.from_now, Time.iso8601(result.dig(:credential_payload, "expires_at")), 5
      end
    end

    assert_equal "https://wbsapi.withings.net/v2/oauth2", posted[0].to_s
    assert_equal "requesttoken", posted[1][:action]
    assert_equal "authorization_code", posted[1][:grant_type]
    assert_equal "provider-code", posted[1][:code]
  end

  test "a non-zero Withings status is an error even though the HTTP status is 200" do
    response = withings_response(status: 503, body: {}, error: "Invalid params")

    with_credentials do
      Net::HTTP.stub(:post_form, response) do
        error = assert_raises(Services::WithingsAdapter::Error) do
          @adapter.exchange_code(code: "bad", attempt: @attempt, redirect_uri: "https://example.test/cb")
        end
        assert_match(/status 503/, error.message)
        assert_match(/Invalid params/, error.message)
      end
    end
  end

  test "refreshes a token that expires within the margin and keeps the rotated refresh token" do
    connection = withings_connection("expires_at" => 10.minutes.from_now.utc.iso8601)
    posted = nil
    response = withings_response(status: 0, body: {
      "userid" => 363, "access_token" => "fresh-access", "refresh_token" => "fresh-refresh", "expires_in" => 10_800
    })

    with_credentials do
      Net::HTTP.stub(:post_form, ->(uri, params) { posted = params; response }) do
        assert_equal "fresh-access", @adapter.current_access_token(connection)
      end
    end

    assert_equal "refresh_token", posted[:grant_type]
    assert_equal "old-refresh", posted[:refresh_token]
    assert_equal "fresh-refresh", connection.reload.credential_payload_hash["refresh_token"]
  end

  test "hands out a token with more than the margin left without calling Withings" do
    connection = withings_connection("expires_at" => 2.hours.from_now.utc.iso8601)

    Net::HTTP.stub(:post_form, ->(*) { flunk "should not refresh" }) do
      assert_equal "current-access", @adapter.current_access_token(connection)
    end
  end

  test "is not offered on a house without its own Withings app" do
    Rails.application.credentials.stub(:dig, nil) do
      assert_not @definition.available?
    end
  end

  private

  def withings_connection(payload)
    accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "withings",
      external_subject_id: "363",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "current-access", "refresh_token" => "old-refresh" }.merge(payload),
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
  end

  def withings_response(status:, body:, error: nil)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    json = { "status" => status, "body" => body }
    json["error"] = error if error
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, json.to_json)
    response
  end

  def with_credentials(&block)
    @adapter.stub(:client_id, "test-withings-client") do
      @adapter.stub(:client_secret, "test-withings-secret", &block)
    end
  end

end
