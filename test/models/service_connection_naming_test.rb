require "test_helper"
require "support/whatsapp_comms_helpers"

class ServiceConnectionNamingTest < ActiveSupport::TestCase

  include WhatsappCommsHelpers

  test "names are trimmed, bounded and resettable without changing authority" do
    connection = whatsapp_connection
    revision = connection.credential_revision
    connection.update!(label: "  Personal  ")
    assert_equal "Personal", connection.reload.label
    assert_equal revision, connection.credential_revision
    assert_not connection.update(label: "x" * 101)
    assert_equal "Personal", connection.reload.label
    connection.update!(label: " \t ")
    assert_nil connection.reload.label
    assert_equal "WhatsApp · #{connection.public_id}", connection.display_label
  end

  test "presentation masks only numeric WhatsApp subjects and never exposes the raw value" do
    connection = whatsapp_connection
    connection.update!(label: "Work", external_subject_id: "447700900123", external_identity: "Sam")
    json = connection.as_connection_json(current_user: users(:user_1))
    assert_equal "Work", json[:custom_label]
    assert_equal "Work", json[:label]
    assert_equal "Sam", json[:identity]
    assert_equal "•••• 0123", json[:whatsapp_identity]
    assert_not_includes json.to_json, "447700900123"
    connection.update!(label: nil)
    assert_equal "•••• 0123", connection.display_label
    [ nil, "1234", "not-a-phone", "12345@s.whatsapp.net" ].each do |subject|
      connection.external_subject_id = subject
      assert_nil connection.whatsapp_identity
    end
    connection.provider = "telegram"
    connection.external_subject_id = "447700900123"
    assert_nil connection.whatsapp_identity
  end

end
