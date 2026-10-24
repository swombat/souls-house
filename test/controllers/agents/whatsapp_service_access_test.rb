require "test_helper"

# Granting a resident WhatsApp access is the ordinary grant: the existing
# controller and ServiceConnection#resident_access_changeable_by?(enabled: true)
# decide, with no comms-specific path.
class Agents::WhatsappServiceAccessTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team)
    @owner = users(:admin)            # connected WhatsApp
    @account_admin = users(:owner)    # account admin, not the connection's owner
    @agent = @account.agents.create!(name: "Comms Reader", model_id: "openrouter/auto")
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @connection = @account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "connected",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
  end

  test "the owner can grant a resident read access" do
    assert @connection.resident_access_changeable_by?(@owner, enabled: true)
    sign_in @owner

    assert_difference -> { @agent.agent_service_accesses.enabled.count }, 1 do
      grant
    end
  end

  test "an account admin cannot grant it unless the owner allows admins to" do
    assert_not @connection.resident_access_changeable_by?(@account_admin, enabled: true)
    sign_in @account_admin

    assert_no_difference -> { AgentServiceAccess.count } do
      grant
    end
    assert_equal "You cannot change this resident's access", flash[:alert]

    @connection.update!(freely_provisionable: true)
    assert @connection.resident_access_changeable_by?(@account_admin, enabled: true)
    assert_difference -> { @agent.agent_service_accesses.enabled.count }, 1 do
      grant
    end
  end

  test "access cannot be granted while pairing" do
    @connection.update!(status: "pairing")
    sign_in @owner

    assert_no_difference -> { AgentServiceAccess.count } do
      grant
    end
  end

  private

  def grant
    patch account_agent_service_access_path(@account, @agent, @connection.public_id), params: { enabled: true }
  end

end
