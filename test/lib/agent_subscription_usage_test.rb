require "test_helper"

class AgentSubscriptionUsageTest < ActiveSupport::TestCase

  test "formats an exhausted provider window in the user's time zone" do
    travel_to Time.utc(2026, 8, 30, 20, 0) do
      usage = AgentSubscriptionUsage.new(
        provider: "xai",
        status: "limited",
        windows: [
          {
            blocking: true,
            remaining_percent: 0,
            resets_at: Time.utc(2026, 8, 30, 22, 32, 46).iso8601
          }
        ]
      )

      assert usage.limited?
      assert_equal(
        "Grok's subscription limit has been reached. It should reset tomorrow at 12:32 AM.",
        usage.user_message(time_zone: "Europe/Madrid")
      )
    end
  end

  test "does not invent a reset time" do
    usage = AgentSubscriptionUsage.new(provider: "openai", status: "limited", windows: [])

    assert_equal(
      "OpenAI's subscription limit has been reached. Please try again later.",
      usage.user_message(time_zone: "UTC")
    )
  end

end
