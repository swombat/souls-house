require "test_helper"

class GuestDiscoveryControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @viewed = accounts(:personal_account)
    @home = Account.create!(name: "Unknown candidate home", account_type: :team)
    @home.add_user!(users(:existing_user), role: "owner", skip_confirmation: true)
    @membership = @home.memberships.create!(user: @user, role: "member", invited_by: users(:existing_user))
    @agent = @home.agents.create!(name: "Discovered resident", runtime: "external", model_id: "openrouter/auto")
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "candidate-only reload discovers confirmed homes and rechecks eligibility and revocation" do
    assert_not_includes candidate_ids, @agent.to_param
    @membership.confirm!
    assert_includes candidate_ids, @agent.to_param
    assert_equal "Discovered resident", candidates.find { |candidate| candidate["id"] == @agent.to_param }.fetch("name")
    @agent.update!(name: "Renamed candidate")
    assert_equal "Renamed candidate", candidates.find { |candidate| candidate["id"] == @agent.to_param }.fetch("name")
    @agent.update!(active: false)
    assert_not_includes candidate_ids, @agent.to_param
    @agent.update!(active: true)
    @home.disable!
    assert_not_includes candidate_ids, @agent.to_param
    @home.enable!
    assert_includes candidate_ids, @agent.to_param
    @membership.update!(confirmed_at: nil)
    assert_not_includes candidate_ids, @agent.to_param
    assert_not response.parsed_body.fetch("props").key?("agents")
    assert_not response.parsed_body.fetch("props").key?("grouped_models")
  end

  test "admin read access does not grant candidate authority without confirmed memberships" do
    sign_in(users(:site_admin_user))
    assert_empty candidates
    assert_response :success
  end

  test "candidate reload does not grant access to a foreign home account" do
    @viewed = @home
    candidates
    assert_response :not_found
  end

  private

  def sign_in(user)
    post login_path, params: { email_address: user.email_address, password: "password123" }
    assert_redirected_to root_path
  end

  def candidates
    get account_agents_path(@viewed), headers: {
      "X-Inertia" => "true",
      "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => "agents/index",
      "X-Inertia-Partial-Data" => "guest_candidates"
    }
    return [] unless response.successful?

    response.parsed_body.fetch("props").fetch("guest_candidates")
  end

  def candidate_ids
    candidates.map { |candidate| candidate.fetch("id") }
  end

end
