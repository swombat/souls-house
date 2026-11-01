require "test_helper"

class OdooServiceConnectionTest < ActiveSupport::TestCase

  test "catalog exposes a personal pasted key without inventing read-only provider scopes" do
    definition = Services::Definition.fetch("odoo")
    assert_equal "credentials", definition.connection_method
    assert_equal "static", definition.credential_strategy
    assert_equal %w[personal], definition.management_scopes
    assert_equal [], definition.scopes_for("user_key")
    assert_equal "password", definition.credential_fields.find { |field| field["key"] == "api_key" }["type"]
    assert_match "full rights", definition.runtime_notes.join(" ")
  end

  test "normal connection flow encrypts the key and exposes metadata without it" do
    definition = Services::Definition.fetch("odoo")
    result = {
      external_subject_id: "https://erp.example.com|books|7",
      external_identity: "reader (books)", label: "Odoo (books)",
      credential_kind: "token", credential_fingerprint: "synthetic-odoo-fingerprint",
      credential_payload: { "api_key" => "synthetic-odoo-secret" },
      credential_metadata: {
        "credential_strategy" => "static", "api_url" => "https://erp.example.com",
        "database" => "books", "login" => "reader", "uid" => 7,
        "protocol" => "jsonrpc", "odoo_version" => "18.0.0",
        "odoo_edition" => "not checked", "accounting_modules" => "not checked",
        "authority_summary" => "Helper reads by convention; user's full rights."
      }
    }
    adapter = Object.new
    adapter.define_singleton_method(:connection_attributes) { |**_| result }
    definition.stub(:adapter, adapter) do
      connection = ServiceConnection.connect_with_credentials!(
        account: accounts(:personal_account), user: users(:user_1),
        definition: definition, management_scope: "personal", credentials: {}
      )
      assert_not_includes connection.reload.ciphertext_for(:credential_payload), "synthetic-odoo-secret"
      entry = connection.runtime_entry(agent: agents(:research_assistant))
      assert_equal({ "api_key" => "synthetic-odoo-secret" }, entry["credentials"])
      assert_equal 7, entry.dig("metadata", "uid")
      assert_not_includes entry["metadata"].to_json, "synthetic-odoo-secret"
      assert_nil entry.dig("access", "scopes")

      connection.disconnect!(revoke_provider: false)
      assert_equal "revoked", connection.reload.status
      assert_empty connection.credential_payload_hash
    end
  end

end
