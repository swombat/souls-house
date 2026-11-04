require "test_helper"

class TwentyServiceConnectionTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "twenty",
      external_subject_id: "https://crm.example.com",
      external_identity: "https://crm.example.com",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "synthetic-fingerprint-not-for-runtime",
      credential_payload_hash: { "api_key" => "synthetic-twenty-key" },
      credential_metadata: {
        "credential_strategy" => "static",
        "api_base" => "https://crm.example.com/rest",
        "authority_summary" => "Actual key permissions are not restricted by the helper."
      }
    )
  end

  def entries
    Agents::ServiceManifest.new(@agent.reload).to_h.fetch("services")
  end

  test "only enabled grants deliver the static key and disabling removes it" do
    assert_empty entries.select { |entry| entry["provider"] == "twenty" }
    access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)

    entry = entries.find { |item| item["provider"] == "twenty" }
    assert_equal "synthetic-twenty-key", entry.dig("credentials", "api_key")
    assert_equal "https://crm.example.com/rest", entry.dig("metadata", "api_base")
    assert_includes entry["notes"].join, "does not restrict the raw key"
    assert_not_includes entry.to_json, "synthetic-fingerprint-not-for-runtime"
    assert_not_includes @connection.read_attribute_before_type_cast(:credential_payload), "synthetic-twenty-key"

    access.update!(enabled: false)
    assert_empty entries.select { |item| item["provider"] == "twenty" }
  end

  test "disconnected keys do not remain in the manifest" do
    @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @connection.disconnect!

    assert_empty entries.select { |item| item["provider"] == "twenty" }
  end

  test "the catalog offers a pasted secret without pretending a read-only authority grant" do
    definition = Services::Definition.fetch("twenty")
    assert_equal "credentials", definition.connection_method
    assert_equal "password", definition.credential_fields.find { |field| field["key"] == "api_key" }["type"]
    assert_empty definition.authority_groups
    assert_includes definition.runtime_notes.join, "may allow writes"
  end

end
