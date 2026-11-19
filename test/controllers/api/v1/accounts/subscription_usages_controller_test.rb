require "test_helper"

class Api::V1::Accounts::SubscriptionUsagesControllerTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper

  setup do
    @owner = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @guest = agents(:other_account_agent)
    [ @agent, @guest ].each do |agent|
      agent.update!(model_id: "openai/gpt-5", provider_auth_modes: { "openai" => "oauth_account" })
    end
    @headers = headers_for(@owner)
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  test "lists only the account's own residents and only allowlisted data, preserving zero" do
    GuestMembership.create!(account: @account, agent: @guest, added_by: @owner)
    freeze_time do
      write_reading(@agent, remaining: 0)
      write_reading(@guest, remaining: 73)

      read_without_refresh(@headers)

      assert_response :ok
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal @account.agents.order(:id).map(&:to_param), residents.pluck("resident_id")
      assert_equal({
        "resident_id" => @agent.to_param, "status" => "available", "stale" => false,
        "checked_at" => Time.current.utc.iso8601,
        "windows" => [ { "id" => "session", "remaining_percent" => 0, "resets_at" => 2.hours.from_now.utc.iso8601 } ]
      }, reading)
    end
  end

  test "marks old and elapsed-window readings stale without starting work even with refresh requested" do
    freeze_time do
      write_reading(@agent, age: 60.seconds)
      read_without_refresh(@headers, refresh: true)
      assert_response :ok
      assert_equal true, reading["stale"]
      assert_equal 60.seconds.ago.utc.iso8601, reading["checked_at"]
      assert_equal 42.5, reading.dig("windows", 0, "remaining_percent")

      write_reading(@agent, age: 20.seconds, resets_at: 1.second.ago)
      read_without_refresh(@headers)
      assert_response :ok
      assert_equal true, reading["stale"]
    end
  end

  test "cold, expired, and unknown readings are unavailable, never zero" do
    freeze_time do
      read_without_refresh(@headers)
      assert_unavailable

      write_reading(@agent, age: 30.minutes)
      read_without_refresh(@headers)
      assert_unavailable

      write_reading(@agent, remaining: nil)
      read_without_refresh(@headers)
      assert_unavailable
    end
  end

  test "does not expose a former subscription reading after switching to an API key" do
    write_reading(@agent)
    @agent.update!(provider_auth_modes: {})

    read_without_refresh(@headers)

    assert_unavailable
  end

  test "an account key is confined to its account even if the caller owns both" do
    read_without_refresh(@headers, account_id: @guest.account.to_param)

    assert_response :not_found
  end

  test "rejects missing auth, resident credentials, and non-owner human roles" do
    read_without_refresh({})
    assert_response :unauthorized

    read_without_refresh(headers_for(@owner, agent: @agent))
    assert_response :forbidden

    read_without_refresh(headers_for(users(:existing_user), account: @guest.account))
    assert_response :forbidden

    admin_account = memberships(:team_admin).account
    read_without_refresh(headers_for(@owner, account: admin_account))
    assert_response :forbidden
  end

  private

  def headers_for(user, account: @account, agent: nil)
    key = ApiKey.generate_for(user, name: "Subscription allowance test", account:, agent:)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

  def read_without_refresh(headers, **params)
    Rails.stub(:cache, @cache) do
      AgentProviderAuthClient.stub(:new, ->(*) { flunk "Started a provider read" }) do
        assert_no_enqueued_jobs(only: RefreshSubscriptionUsageJob) do
          get api_v1_account_subscription_usage_path, headers:, params:
        end
      end
    end
  end

  def write_reading(agent, age: 0.seconds, remaining: 42.5, resets_at: 2.hours.from_now)
    @cache.write(Agents::SubscriptionUsageSnapshot.new(agent).cache_key, {
      "fetched_at" => age.ago.to_f,
      "snapshot" => {
        "provider_account" => "private metadata",
        "windows" => [ {
          "id" => "session", "remaining_percent" => remaining, "resets_at" => resets_at.utc.iso8601,
          "provider_metadata" => "not for the API"
        } ]
      }
    })
  end

  def residents = response.parsed_body.fetch("residents")
  def reading = residents.find { |row| row["resident_id"] == @agent.to_param }

  def assert_unavailable
    assert_response :ok
    assert_equal({
      "resident_id" => @agent.to_param, "status" => "unavailable", "stale" => nil,
      "checked_at" => nil, "windows" => []
    }, reading)
  end

end
