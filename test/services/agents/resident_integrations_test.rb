require "test_helper"

class Agents::ResidentIntegrationsTest < ActiveSupport::TestCase
  test "account repository icons reflect each grant and expose no credentials" do
    agent = agents(:research_assistant)
    account = agent.account
    connections = %w[first second].map do |repo|
      account.service_connections.create!(provider: "github", connected_by_user: users(:user_1),
        management_scope: "personal", credential_kind: "token", credential_fingerprint: repo,
        credential_payload_hash: { "token" => "private-token" },
        credential_metadata: { "repository" => "owner/#{repo}" })
    end
    agent.agent_service_accesses.create!(service_connection: connections.first, enabled: true)
    icons = Agents::ResidentIntegrations.new(account, [ agent ]).for(agent)
    assert_equal %w[owner/first owner/second], icons.map { |icon| icon[:label] }
    assert_equal [ true, false ], icons.map { |icon| icon[:enabled] }
    assert_not_includes icons.to_json, "private-token"
    connections.first.update_columns(status: "revoked")
    assert_not Agents::ResidentIntegrations.new(account, [ agent ]).for(agent).first[:enabled]
  end
end
