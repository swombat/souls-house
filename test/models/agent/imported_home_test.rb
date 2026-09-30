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

  test "imported is a class of profile: mira_v1 and portable_v1" do
    agent = agents(:research_assistant)
    agent.assign_attributes(home_profile: "mira_v1", portable_home_id: "test-mira")
    assert agent.valid?
    assert agent.imported_home?
    assert_equal "MIRA_ROOT", agent.imported_home_root_env
    agent.assign_attributes(home_profile: "portable_v1", portable_home_id: "test-lume")
    assert agent.valid?
    assert agent.imported_home?
    assert_equal "SOULSHOUSE_HOME_ROOT", agent.imported_home_root_env
  end

  test "portable_v1 also requires a portable identity" do
    agent = agents(:research_assistant)
    agent.assign_attributes(home_profile: "portable_v1", portable_home_id: nil)
    assert_not agent.valid?
    assert agent.errors[:portable_home_id].any?
  end

  test "an unknown profile is invalid and is not treated as imported or house" do
    agent = agents(:research_assistant)
    agent.assign_attributes(home_profile: "mira_v2", portable_home_id: "test-other")
    assert_not agent.valid?
    assert agent.errors[:home_profile].any?
    assert_not agent.imported_home?
  end

  test "portable_v1 does not create a second memory vault either" do
    agent = agents(:research_assistant)
    agent.update!(home_profile: "portable_v1", portable_home_id: "test-lume")
    assert_no_difference "Mnemodyne::Vault.count" do
      assert_nil Mnemodyne::Provision.call(agent, deliberate: true)
    end
  end

  test "imported home does not create a second memory vault" do
    agent = agents(:research_assistant)
    agent.update!(home_profile: "mira_v1", portable_home_id: "test-mira")
    assert_no_difference "Mnemodyne::Vault.count" do
      assert_nil Mnemodyne::Provision.call(agent, deliberate: true)
    end
  end
end
