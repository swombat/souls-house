require "test_helper"

class Services::PipedriveTokenAdapterTest < ActiveSupport::TestCase

  setup do
    @adapter = Services::PipedriveTokenAdapter.new(Services::Definition.fetch("pipedrive"))
  end

  test "builds a static credential connection that acts as the token's user" do
    me = {
      "success" => true,
      "data" => {
        "id" => 7,
        "name" => "Paulina",
        "email" => "paulina@example.com",
        "company_id" => 99,
        "company_name" => "Example Ltd",
        "company_domain" => "example"
      }
    }

    @adapter.stub :get_json, ->(domain, path, token) {
      assert_equal "example", domain
      assert_equal "/api/v1/users/me", path
      assert_equal "pd_secret", token
      me
    } do
      result = @adapter.connection_attributes(
        credentials: { "api_token" => " pd_secret ", "company_domain" => "https://Example.pipedrive.com/" },
        user: users(:user_1)
      )

      assert_equal "99:7", result[:external_subject_id]
      assert_equal "paulina@example.com", result[:external_identity]
      assert_equal "Example Ltd (paulina@example.com)", result[:label]
      assert_equal "token", result[:credential_kind]
      assert_equal({ "api_token" => "pd_secret" }, result[:credential_payload])
      assert_equal "example", result.dig(:credential_metadata, "company_domain")
      assert_equal "https://example.pipedrive.com/api", result.dig(:credential_metadata, "api_base")
      assert_equal "static", result.dig(:credential_metadata, "credential_strategy")
      assert_not_includes result[:credential_metadata].values.join(" "), "pd_secret"
      assert_not_includes result[:credential_fingerprint], "pd_secret"
    end
  end

  test "refuses a token that belongs to a different company" do
    me = { "data" => { "id" => 1, "email" => "a@b.c", "company_id" => 2, "company_domain" => "othercorp" } }

    @adapter.stub :get_json, ->(*) { me } do
      error = assert_raises(Services::PipedriveTokenAdapter::Error) do
        @adapter.connection_attributes(
          credentials: { "api_token" => "pd_secret", "company_domain" => "example" },
          user: users(:user_1)
        )
      end

      assert_match "othercorp.pipedrive.com", error.message
    end
  end

  test "rejects a malformed company domain before making requests" do
    error = assert_raises(Services::PipedriveTokenAdapter::Error) do
      @adapter.connection_attributes(
        credentials: { "api_token" => "pd_secret", "company_domain" => "evil.com/x?y" },
        user: users(:user_1)
      )
    end

    assert_equal "Company domain must be the part before .pipedrive.com", error.message
  end

  test "requires a token" do
    error = assert_raises(Services::PipedriveTokenAdapter::Error) do
      @adapter.connection_attributes(credentials: { "company_domain" => "example" }, user: users(:user_1))
    end

    assert_equal "Pipedrive API token is required", error.message
  end

  test "normalizes the forms people paste for the company domain" do
    %w[example Example.pipedrive.com https://example.pipedrive.com/ https://example.pipedrive.com/pipeline/1].each do |input|
      assert_equal "example", Services::PipedriveTokenAdapter.normalize_domain(input), input
    end
  end

end
