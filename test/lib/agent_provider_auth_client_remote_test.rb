require "test_helper"

# A resident on its own VM is logged in through its runner (#246 parity).
class AgentProviderAuthClientRemoteTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(trigger_bearer_token: "trig", container_name: "hk-agent-vm")
    AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
  end

  test "calls go through the runner relay with the same paths and parameters" do
    calls = []
    relay = lambda do |agent, method:, path:, params:|
      calls << [ agent.id, method, path, params ]
      { "status" => 200, "body" => { "connected" => true } }
    end
    Agents::RemoteRuntime.stub(:provider_auth!, relay) do
      client = AgentProviderAuthClient.new(@agent)
      assert_equal({ "connected" => true }, client.status(provider: "anthropic"))
      client.submit_code(provider: "anthropic", code: "abc")
    end
    assert_equal [ @agent.id, "GET", "/auth/status", { provider: "anthropic" } ], calls[0]
    assert_equal [ @agent.id, "POST", "/auth/code", { provider: "anthropic", code: "abc" } ], calls[1]
  end

  test "a refusal from the resident and an unanswered relay both become client errors" do
    Agents::RemoteRuntime.stub(:provider_auth!, ->(*, **) { { "status" => 409, "body" => { "error" => "login in progress" } } }) do
      error = assert_raises(AgentProviderAuthClient::Error) { AgentProviderAuthClient.new(@agent).start(provider: "anthropic") }
      assert_equal 409, error.status
      assert_equal "login in progress", error.message
    end
    Agents::RemoteRuntime.stub(:provider_auth!, ->(*, **) { raise Agents::RemoteRuntime::Unavailable, "did not answer" }) do
      error = assert_raises(AgentProviderAuthClient::Error) { AgentProviderAuthClient.new(@agent).capabilities }
      assert_equal "did not answer", error.message
    end
  end

end
