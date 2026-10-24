require "test_helper"

class IntegrationPresentationTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @account = accounts(:personal_account)
    @stream = "IntegrationStatus:#{@account.to_param}"
    @agent = agents(:research_assistant)
  end

  test "resident name and eligibility refresh but ordinary operational edits do not" do
    assert_marker { @agent.update!(name: "Renamed resident") }
    assert_marker { @agent.update!(active: false) }
    assert_no_broadcasts(@stream) { @agent.update!(turn_timeout_minutes: 45) }
    assert_no_broadcasts(@stream) { @agent.touch }
  end

  test "resident lifecycle refreshes an initially empty list" do
    resident = nil
    assert_marker do
      resident = @account.agents.create!(name: "New resident", runtime: "external", active: false)
    end
    assert_marker { resident.destroy! }
  end

  test "current-account membership role and confirmation update permissions" do
    account = accounts(:team_account)
    stream = "IntegrationStatus:#{account.to_param}"
    member = memberships(:team_member)
    assert_broadcasts(stream, 1) { member.update!(role: "admin") }
    assert_broadcasts(stream, 1) { member.update!(confirmed_at: nil) }
    assert_no_broadcasts(stream) { member.touch }
  end

  test "presentation transitions survive a later touch but not transaction rollback" do
    assert_marker do
      Agent.transaction do
        @agent.update!(name: "Changed before touch")
        @agent.touch
      end
    end
    assert_no_broadcasts(@stream) do
      Agent.transaction do
        @agent.update!(active: false)
        raise ActiveRecord::Rollback
      end
    end
  end

  test "owner names invalidate only accounts containing that owner's connections" do
    owner = users(:user_1)
    @account.service_connections.create!(
      connected_by_user: owner, provider: "oura", external_subject_id: "presentation-owner",
      management_scope: "personal", credential_kind: "oauth2", status: "connected"
    )
    assert_marker { owner.profile.update!(first_name: "Updated") }
    assert_marker { owner.update!(email_address: "updated-owner@example.com") }
    assert_no_broadcasts(@stream) { owner.profile.update!(timezone: "UTC") }
    assert_no_broadcasts("IntegrationStatus:#{accounts(:existing_user_account).to_param}") do
      owner.profile.update!(last_name: "New name")
    end
  end

  test "ordinary chat traffic does not invalidate integration presentation" do
    assert_no_broadcasts(@stream) do
      chat = @account.chats.create!(title: "Quiet integration", model_id: "openrouter/auto")
      chat.messages.create!(role: "assistant", content: "Hello")
    end
  end

  private

  def assert_marker(&block)
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream, &block)
  end

end
