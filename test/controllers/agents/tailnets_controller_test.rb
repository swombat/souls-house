require "test_helper"

class Agents::TailnetsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @connection = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "tailscale",
      label: "Tailnet",
      management_scope: "personal",
      credential_kind: "none",
      credential_fingerprint: "tailnet-sign-in-fingerprint",
      credential_metadata: { "credential_strategy" => "static", "join" => "sign_in", "hosts" => [] }
    )
    sign_in @user
  end

  test "is not found until Tailscale is enabled for the resident" do
    get account_agent_tailnet_path(@account, @agent), as: :json
    assert_response :not_found
  end

  test "reports the node's sign-in link from inside the resident" do
    enable!
    report = { "backend_state" => "NeedsLogin", "auth_url" => "https://login.tailscale.com/a/abc", "hosts" => [] }

    with_tailnet(up: report) do
      post account_agent_tailnet_path(@account, @agent), as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert body["available"]
    assert_equal "https://login.tailscale.com/a/abc", body["auth_url"]
  end

  test "says plainly when the resident's container can't answer yet" do
    enable!(provisioning_status: "pending")

    with_tailnet(status: Agents::Tailnet::Unavailable.new("no Tailscale integration is granted to this resident")) do
      get account_agent_tailnet_path(@account, @agent), as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_not body["available"]
    assert_equal "pending", body["provisioning_status"]
    assert_match(/no Tailscale integration/, body["error"])
  end

  private

  def enable!(provisioning_status: "active")
    @agent.agent_service_accesses.find_or_create_by!(service_connection: @connection)
      .update!(enabled: true, provisioning_status: provisioning_status)
  end

  def with_tailnet(status: nil, up: nil)
    fake = Object.new
    fake.define_singleton_method(:status) { status.is_a?(Exception) ? raise(status) : status }
    fake.define_singleton_method(:up) { up.is_a?(Exception) ? raise(up) : up }
    Agents::Tailnet.stub(:new, fake) { yield }
  end

end
