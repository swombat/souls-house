# Shared setup for the LinkedIn connector tests.
module LinkedinTestHelpers

  def linkedin_connection(account:, user:, payload: {}, status: "connected")
    account.service_connections.create!(
      connected_by_user: user,
      provider: "linkedin",
      external_subject_id: "abc123",
      external_identity: "Daniel Tenner",
      management_scope: "personal",
      status: status,
      credential_kind: "oauth2",
      credential_payload_hash: {
        "access_token" => "li-access",
        "expires_at" => 30.days.from_now.utc.iso8601,
        "author_urn" => "urn:li:person:abc123"
      }.merge(payload),
      credential_metadata: { "credential_strategy" => "house_poster", "granted_scopes" => %w[openid profile w_member_social] }
    )
  end

  def with_linkedin_credentials(&block)
    original = Rails.application.credentials.method(:dig)
    stub = ->(*keys) { keys.first == :linkedin ? { client_id: "li-client", client_secret: "li-secret" }.dig(*keys.drop(1)) : original.call(*keys) }
    Rails.application.credentials.stub(:dig, stub, &block)
  end

end
