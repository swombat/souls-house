require "test_helper"

class AccountCostPartialsTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    sign_in users(:user_1)
  end

  test "navbar partials skip both report and roster builders" do
    original = Accounts::CostsController.instance_method(:cost_agents)
    Accounts::CostsController.define_method(:cost_agents) { raise "unrequested cost roster" }
    AccountInteractionCostReport.stub :new, ->(*) { flunk "unrequested cost report" } do
      %w[room_activity accounts,expired_subscriptions reply_attention,accounts,expired_subscriptions rooms,current_room].each do |props|
        get account_costs_path(@account), headers: partial(props)
        assert_response :success
        assert_not response.parsed_body.fetch("props").key?("agents")
        assert_not response.parsed_body.fetch("props").key?("cost_report")
      end
    end
  ensure
    if original
      Accounts::CostsController.define_method(:cost_agents, original)
      Accounts::CostsController.send(:private, :cost_agents)
    end
  end

  test "cost-only partial skips roster and requested discovery includes both" do
    original = Accounts::CostsController.instance_method(:cost_agents)
    Accounts::CostsController.define_method(:cost_agents) { raise "cost-only rebuilt roster" }
    get account_costs_path(@account), headers: partial("cost_report")
    assert_response :success
    assert response.parsed_body.fetch("props").key?("cost_report")
    assert_not response.parsed_body.fetch("props").key?("agents")
    Accounts::CostsController.define_method(:cost_agents, original)
    get account_costs_path(@account), headers: partial("agents,cost_report")
    assert_response :success
    assert response.parsed_body.fetch("props").key?("cost_report")
    assert response.parsed_body.fetch("props").key?("agents")
  ensure
    if original
      Accounts::CostsController.define_method(:cost_agents, original)
      Accounts::CostsController.send(:private, :cost_agents)
    end
  end

  private

  def partial(props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => "accounts/costs", "X-Inertia-Partial-Data" => props
    }
  end

end
