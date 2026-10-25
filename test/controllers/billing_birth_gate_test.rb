require "test_helper"
require_relative "../support/github_import_fixtures"

# An account that pays for new residents can create one only by paying for it
# in the creation wizard (Billing::PaidBirth). Every other route is refused,
# with the reason, before anything is committed; with Stripe not configured,
# the wizard says so up front. Accounts that don't pay are unaffected.
class BillingBirthGateTest < ActionDispatch::IntegrationTest

  include GithubImportFixtures

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    sign_in(users(:user_1))
  end

  test "the creation page shows the reason and a birth commits nothing" do
    get new_account_agent_path(@account)
    assert_equal Billing::BirthGate::NOT_OPEN, inertia_shared_props.fetch("vm_birth_refusal")

    assert_no_difference [ "Agent.count", "ApiKey.count", "HouseInferenceGrant.count" ] do
      assert_no_enqueued_jobs only: ProvisionAgentJob do
        post account_agents_path(@account), params: {
          agent: { name: "Not yet", system_prompt: "You are helpful", model_id: "openrouter/auto" }
        }
      end
    end
    assert_redirected_to new_account_agent_path(@account)
  end

  test "an account that doesn't pay creates residents as before" do
    @account.update!(billing_required: false)
    get new_account_agent_path(@account)
    assert_nil inertia_shared_props.fetch("vm_birth_refusal")

    assert_difference "Agent.count", 1 do
      post account_agents_path(@account), params: {
        agent: { name: "On the house", system_prompt: "You are helpful", model_id: "openrouter/auto" }
      }
    end
  end

  test "the API refuses a birth and says why in the catalogue" do
    token = ApiKey.generate_for(users(:user_1), name: "Residents", account: @account).raw_token
    headers = { "Authorization" => "Bearer #{token}" }

    get catalogue_api_v1_residents_url, headers: headers
    assert_equal Billing::BirthGate::NEEDS_PLAN, response.parsed_body.fetch("birth_refusal")

    assert_no_difference "Agent.count" do
      post api_v1_residents_url, headers: headers, as: :json, params: {
        agent: { name: "Not yet", system_prompt: "Be kind", model_id: "openrouter/auto" }
      }
    end
    assert_response :unprocessable_entity
    assert_equal Billing::BirthGate::NEEDS_PLAN, response.parsed_body.fetch("error")
  end

  test "an archive import is refused before the upload is read" do
    assert_no_difference [ "Agent.count", "ApiKey.count" ] do
      post import_archive_account_agents_path(@account), params: { confirmed: "true", name: "Copy" }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "need a plan"
  end

  test "a GitHub import request is refused" do
    connection = import_connection(account: @account)
    Agents::GithubImportSource.stub(:new, source_stub) do
      assert_no_difference [ "GithubResidentImport.count", "Agent.count" ] do
        post account_github_resident_imports_path(@account), params: {
          github_resident_import: { name: "From GitHub", model_id: Chat::MODELS.first[:model_id],
            service_connection_id: connection.public_id, branch: "main" }
        }
      end
    end
    assert_redirected_to new_account_github_resident_import_path(@account)
  end

end
