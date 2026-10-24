require "test_helper"

class ProviderPresentationTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Provider presentation #{SecureRandom.hex(4)}", account_type: :team)
    @other = Account.create!(name: "Provider other #{SecureRandom.hex(4)}", account_type: :team)
    @agent = @account.agents.create!(name: "Synthetic provider", runtime: "external", model_id: "anthropic/claude-opus-4.6")
    clear_enqueued_jobs
  end

  teardown do
    [ @account, @other ].each { |account| account.reload.destroy! }
  end

  test "provider presentation is a pure persisted read with no runtime client or writes" do
    @agent.record_provider_connection!("anthropic", status: "connected", email: "synthetic@example.test", plan: "test")
    before = @agent.reload.attributes
    Agents::Sandbox.stub :new, ->(*) { flunk "presentation instantiated provider runtime" } do
      assert_no_enqueued_jobs do
        value = Agents::ProviderSubscriptionPresentation.call(@agent)
        assert_equal "connected", value.dig(:connection, "status")
        assert_equal "anthropic", value[:provider]
      end
    end
    assert_equal before, @agent.reload.attributes
  end

  test "rendered fields and selected provider connection emit content-free hints" do
    [
      -> { @agent.update!(name: "New label") },
      -> { @agent.update!(health_state: "healthy") },
      -> { @agent.use_provider_auth_mode!("anthropic", "oauth_account") },
      -> { @agent.record_provider_connection!("anthropic", status: "connected", email: "PRIVATE-SENTINEL", plan: "test") },
      -> { @agent.mark_provider_connection_status!("anthropic", "expired") },
      -> { @agent.clear_provider_connection!("anthropic") },
      -> { @agent.update!(runtime: "offline") }
    ].each { |write| assert_marker(&write) }
  end

  test "unrendered JSON keys other providers and equivalent unavailable health stay quiet" do
    assert_no_broadcasts(stream) do
      @agent.update!(provider_connections: { "anthropic" => { "connected_at" => Time.current.iso8601, "private_future" => "secret" } })
      @agent.update!(provider_connections: @agent.provider_connections.merge("openai" => { "status" => "connected" }))
      @agent.use_provider_auth_mode!("openai", "oauth_account")
      @agent.update!(health_state: "unhealthy")
      @agent.update!(last_health_check_at: Time.current)
      @agent.touch
    end
  end

  test "writes wait for commit retain earlier visible change and drop rolled back savepoints" do
    assert_marker do
      Agent.transaction do
        assert_no_broadcasts(stream) do
          @agent.update!(name: "Committed label")
          @agent.touch
          @agent.reload
        end
      end
    end
    assert_no_broadcasts(stream) do
      Agent.transaction do
        Agent.transaction(requires_new: true) do
          @agent.update!(name: "Rolled back label")
          raise ActiveRecord::Rollback
        end
      end
      @agent.reload
      Agent.transaction do
        @agent.update!(name: "Outer rollback")
        raise ActiveRecord::Rollback
      end
    end
  end

  test "arrival deletion and account reassignment signal affected existing accounts" do
    arrival = nil
    assert_marker { arrival = @account.agents.create!(name: "Another provider", runtime: "offline", model_id: "anthropic/claude-opus-4.6") }
    assert_broadcasts("ProviderPresentation:#{@other.to_param}", 1) do
      assert_marker { arrival.update!(account: @other) }
    end
    assert_broadcasts("ProviderPresentation:#{@other.to_param}", 1) { arrival.destroy! }
  end

  test "provider and model transitions are visible but unsupported arrivals stay quiet" do
    assert_marker { @agent.update!(model_id: "openai/gpt-5") }
    assert_marker { @agent.update!(model_id: "openai/gpt-5.1") }
    unsupported = nil
    assert_no_broadcasts(stream) do
      unsupported = @account.agents.create!(name: "Unsupported", runtime: "offline", model_id: "openrouter/auto")
      unsupported.update!(name: "Still unsupported")
      unsupported.destroy!
    end
  end

  test "membership permission changes reuse the existing hook" do
    membership = nil
    assert_marker { membership = @account.add_user!(users(:existing_user), role: "member", skip_confirmation: true) }
    assert_marker { membership.update!(role: "admin") }
    assert_marker { membership.destroy! }
  end

  private

  def stream
    "ProviderPresentation:#{@account.to_param}"
  end

  def assert_marker
    markers = capture_broadcasts(stream) { yield }
    assert_equal [ { "action" => "refresh" } ], markers
  end

end
