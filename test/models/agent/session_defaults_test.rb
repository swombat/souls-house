require "test_helper"

class Agent::SessionDefaultsTest < ActiveSupport::TestCase

  test "new residents continue conversation and heartbeat sessions by default" do
    agent = Agent.new
    assert agent.persistent_session?
    assert agent.persistent_wake_session?
  end

  test "explicit choices survive saving and unrelated edits" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: false, persistent_wake_session: false)
    agent.update!(name: "Still starts fresh")
    assert_not agent.reload.persistent_session?
    assert_not agent.persistent_wake_session?

    fresh = Agent.new(persistent_session: false, persistent_wake_session: false)
    assert_not fresh.persistent_session?
    assert_not fresh.persistent_wake_session?
  end

end
