require "test_helper"

class Services::GithubTokenAdapterTest < ActiveSupport::TestCase

  setup do
    @adapter = Services::GithubTokenAdapter.new(Services::Definition.fetch("github"))
  end

  test "builds a repository-specific static credential connection" do
    responses = {
      "/user" => { "id" => 42, "login" => "dad" },
      "/repos/dad/example-site" => {
        "id" => 123,
        "full_name" => "dad/example-site",
        "clone_url" => "https://github.com/dad/example-site.git",
        "default_branch" => "main",
        "private" => true
      }
    }

    @adapter.stub :get_json, ->(path, token) {
      assert_equal "github_pat_secret", token
      responses.fetch(path)
    } do
      result = @adapter.connection_attributes(
        credentials: {
          "token" => "github_pat_secret",
          "repository" => "dad/example-site"
        },
        user: users(:user_1)
      )

      assert_equal "42", result[:external_subject_id]
      assert_equal "dad", result[:external_identity]
      assert_equal "dad/example-site", result[:label]
      assert_equal "token", result[:credential_kind]
      assert_equal "github_pat_secret", result.dig(:credential_payload, "token")
      assert_equal "dad/example-site", result.dig(:credential_metadata, "repository")
      assert result[:credential_fingerprint].present?
      assert_not_includes result[:credential_fingerprint], "github_pat_secret"
    end
  end

  test "creates distinct fingerprints for distinct tokens from the same user" do
    first = @adapter.send(:credential_fingerprint, "github_pat_first")
    second = @adapter.send(:credential_fingerprint, "github_pat_second")

    assert_not_equal first, second
    assert_equal first, @adapter.send(:credential_fingerprint, "github_pat_first")
  end

  test "requires owner and repository syntax before making requests" do
    error = assert_raises(Services::GithubTokenAdapter::Error) do
      @adapter.connection_attributes(
        credentials: { "token" => "github_pat_secret", "repository" => "not a repository" },
        user: users(:user_1)
      )
    end

    assert_equal "Repository must use the owner/repository format", error.message
  end

  test "token kind does not pretend to prove repository restrictions and missing scopes stay unknown" do
    fine = Services::GithubTokenAdapter.authority_metadata("github_pat_synthetic")
    assert_equal "fine_grained", fine["token_kind"]
    assert_nil fine["oauth_scopes"]
    classic = Services::GithubTokenAdapter.authority_metadata("ghp_synthetic", scopes: %w[repo workflow])
    assert_equal "classic", classic["token_kind"]
    assert_equal %w[repo workflow], classic["oauth_scopes"]
    assert_equal "X-OAuth-Scopes", classic["authority_source"]
    assert_equal "unknown", Services::GithubTokenAdapter.authority_metadata("other")["token_kind"]
  end

  test "preserves provider reported classic OAuth scopes without exposing token" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["X-OAuth-Scopes"] = "repo, workflow"
    response.body = JSON.generate(id: 42, login: "synthetic")
    response.instance_variable_set(:@read, true)
    http = Object.new
    http.define_singleton_method(:request) { |_| response }
    Net::HTTP.stub(:start, ->(*_, **_, &block) { block.call(http) }) { @adapter.send(:get_json, "/user", "ghp_synthetic") }
    assert_equal %w[repo workflow], @adapter.instance_variable_get(:@oauth_scopes)
  end

end
