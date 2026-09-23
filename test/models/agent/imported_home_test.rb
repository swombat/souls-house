require "test_helper"

class Agent::ImportedHomeTest < ActiveSupport::TestCase
  test "stock residents retain the house profile" do
    assert_equal "house", agents(:research_assistant).home_profile
    assert_not agents(:research_assistant).imported_home?
  end

  test "portable identity is required and unique across accounts" do
    agent = agents(:research_assistant)
    agent.assign_attributes(home_profile: "mira_v1", portable_home_id: nil)
    assert_not agent.valid?
    agent.update!(portable_home_id: "test-mira")
    other = agents(:other_account_agent)
    other.assign_attributes(home_profile: "mira_v1", portable_home_id: "test-mira")
    assert_not other.valid?
    assert_includes other.errors[:portable_home_id], "has already been taken"
  end

  test "imported home does not create a second memory vault" do
    agent = agents(:research_assistant)
    agent.update!(home_profile: "mira_v1", portable_home_id: "test-mira")
    assert_no_difference "Mnemodyne::Vault.count" do
      assert_nil Mnemodyne::Provision.call(agent, deliberate: true)
    end
  end
end
