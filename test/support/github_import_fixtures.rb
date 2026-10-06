module GithubImportFixtures

  def import_connection(account: accounts(:personal_account), token: "github_pat_synthetic")
    fingerprint = Services::GithubTokenAdapter.new(Services::Definition.fetch("github")).send(:credential_fingerprint, token)
    connection = account.service_connections.new(
      provider: "github", connected_by_user: account.owner, management_scope: "personal",
      status: "connected", credential_kind: "token", credential_fingerprint: fingerprint,
      credential_metadata: Services::GithubTokenAdapter.authority_metadata(token).merge(
        "repository" => "example/resident", "repository_id" => "42", "default_branch" => "main"))
    connection.credential_payload_hash = { "token" => token }
    connection.save!
    connection
  end

  def import_request(connection: import_connection, **attrs)
    GithubResidentImport.create!({
      account: connection.account, service_connection: connection, requested_by: connection.connected_by_user,
      name: "Imported test resident", model_id: Chat::MODELS.first[:model_id],
      repository: "example/resident", repository_id: "42", branch: "main",
      commit_sha: "a" * 40, portable_home_id: "synthetic-portable-home",
      credential_fingerprint: connection.credential_fingerprint,
      token_metadata: connection.credential_metadata.slice("token_kind", "oauth_scopes", "authority_source", "authority_warnings")
    }.merge(attrs))
  end

  def approve_fixture(request, by: users(:user_1))
    request.update!(status: "approved", approved_by: by, approved_at: Time.current,
      approved_commit_sha: request.commit_sha, approved_credential_fingerprint: request.credential_fingerprint,
      approved_image: Agents::Config.default_image)
  end

  def source_stub(request = nil)
    source = Object.new
    source.define_singleton_method(:with_checkout) do |branch:, commit_sha: nil, &block|
      block.call("/synthetic-home", { "identity_id" => request&.portable_home_id || "synthetic-portable-home" },
        commit_sha || "a" * 40, branch.presence || "main")
    end
    source
  end

end
