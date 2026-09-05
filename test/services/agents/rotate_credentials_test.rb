require "test_helper"

class Agents::RotateCredentialsTest < ActiveSupport::TestCase

  test "rotation revokes every resident key but preserves peers and backup encryption" do
    agent = agents(:research_assistant)
    key = ApiKey.generate_for(users(:user_1), name: "Primary", agent: agent)
    peer = ApiKey.generate_for(users(:user_1), name: "Peer", agent: agents(:code_reviewer))
    agent.update!(outbound_api_key: key, outbound_api_token: key.raw_token,
      trigger_bearer_token: "old", restic_password: "synthetic-backup-password")
    Agents::RotateCredentials.call(agent)
    assert_nil ApiKey.authenticate(key.raw_token)
    assert ApiKey.authenticate(peer.raw_token)
    assert_equal agent.id, ApiKey.authenticate(agent.reload.outbound_api_token).agent_id
    assert_not_equal "old", agent.trigger_bearer_token
    assert_equal "synthetic-backup-password", agent.restic_password
  end

end
