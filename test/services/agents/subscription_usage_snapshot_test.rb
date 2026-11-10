require "test_helper"

class Agents::SubscriptionUsageSnapshotTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @agent = agents(:other_account_agent)
    @agent.update!(
      model_id: "openai/gpt-5",
      provider_auth_modes: { "openai" => "oauth_account" },
      runtime: "external",
      trigger_bearer_token: "trigger-secret",
      endpoint_url: "https://agent.example.com"
    )
    @store = ActiveSupport::Cache::MemoryStore.new
    @reads = []
  end

  test "a first look reads live and keeps the reading" do
    with_client(remaining: 72) do
      result = Agents::SubscriptionUsageSnapshot.fetch(@agent)

      assert_equal 72, result.dig("windows", 0, "remaining_percent")
      assert_equal false, result["stale"]
      assert result["checked_at"].present?
    end
    assert_equal [ false ], @reads
  end

  test "a fresh reading is served without asking the runtime" do
    with_client(remaining: 72) do
      Agents::SubscriptionUsageSnapshot.fetch(@agent)
      travel 59.seconds do
        assert_no_enqueued_jobs do
          assert_equal false, Agents::SubscriptionUsageSnapshot.fetch(@agent)["stale"]
        end
      end
    end
    assert_equal 1, @reads.size
  end

  test "an older reading is served at once, marked stale, and refreshed once in the background" do
    with_client(remaining: 72) do
      Agents::SubscriptionUsageSnapshot.fetch(@agent)
      travel 5.minutes do
        assert_enqueued_jobs 1, only: RefreshSubscriptionUsageJob do
          3.times do
            result = Agents::SubscriptionUsageSnapshot.fetch(@agent)
            assert_equal true, result["stale"]
            assert_equal 72, result.dig("windows", 0, "remaining_percent")
          end
        end
        assert_equal 1, @reads.size, "the request did not wait on the runtime"

        @remaining = 40
        perform_enqueued_jobs
        result = Agents::SubscriptionUsageSnapshot.fetch(@agent)
        assert_equal false, result["stale"]
        assert_equal 40, result.dig("windows", 0, "remaining_percent")
      end
    end
    assert_equal 2, @reads.size
  end

  test "a reading older than the stale limit is read again live" do
    with_client(remaining: 72) do
      Agents::SubscriptionUsageSnapshot.fetch(@agent)
      travel 31.minutes do
        assert_no_enqueued_jobs { assert_equal false, Agents::SubscriptionUsageSnapshot.fetch(@agent)["stale"] }
      end
    end
    assert_equal 2, @reads.size
  end

  test "asking for a refresh reads live and passes the refresh on" do
    with_client(remaining: 72) do
      Agents::SubscriptionUsageSnapshot.fetch(@agent)
      Agents::SubscriptionUsageSnapshot.fetch(@agent, refresh: true)
    end
    assert_equal [ false, true ], @reads
  end

  test "a limit whose reset has passed is not served from the cache" do
    @status = "limited"
    @resets_at = 2.minutes.from_now.iso8601
    with_client(remaining: 0) do
      Agents::SubscriptionUsageSnapshot.fetch(@agent)
      travel 3.minutes do
        @status = "available"
        assert_equal "available", Agents::SubscriptionUsageSnapshot.fetch(@agent)["status"]
      end
    end
    assert_equal 2, @reads.size
  end

  test "a failed background refresh keeps the last reading and frees the lock" do
    with_client(remaining: 72) do
      Agents::SubscriptionUsageSnapshot.fetch(@agent)
      travel 5.minutes do
        Agents::SubscriptionUsageSnapshot.fetch(@agent)
        @fail = true
        perform_enqueued_jobs
        result = Agents::SubscriptionUsageSnapshot.fetch(@agent)
        assert_equal true, result["stale"]
        assert_equal 72, result.dig("windows", 0, "remaining_percent")
        assert_enqueued_jobs 1, only: RefreshSubscriptionUsageJob
      end
    end
  end

  private

  def with_client(remaining:)
    @remaining = remaining
    test = self
    client = Object.new
    client.define_singleton_method(:usage) do |provider:, model:, refresh:|
      test.instance_variable_get(:@reads) << refresh
      raise AgentProviderAuthClient::Error, "runtime away" if test.instance_variable_get(:@fail)

      {
        "provider" => provider,
        "status" => test.instance_variable_get(:@status) || "available",
        "windows" => [ {
          "id" => "session", "remaining_percent" => test.instance_variable_get(:@remaining),
          "blocking" => true, "resets_at" => test.instance_variable_get(:@resets_at)
        } ]
      }
    end
    Rails.stub(:cache, @store) do
      AgentProviderAuthClient.stub(:new, client) { yield }
    end
  end

end
