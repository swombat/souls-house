require "test_helper"

class ChatMentionsTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @first = resident("Echo")
    @second = resident("eCHO")
    @chat = @account.chats.create!(title: "Mention resolution", manual_responses: true,
      agents: [ @second, @first ])
  end

  test "duplicate names select the lowest database ID not creation time or association order" do
    @first.update_columns(created_at: 1.day.ago)
    @second.update_columns(created_at: 2.days.ago)

    assert_operator @first.id, :<, @second.id
    assert_operator @first.created_at, :>, @second.created_at
    # Exercise a loaded association deliberately ordered against database ID.
    @chat.agents.load_target.replace([ @second, @first ])

    assert_targets "@ECHO", immediate: [ @first.id ]
  end

  test "busy lowest ID namesake is queued without waking the free namesake" do
    assert_targets "@Echo", busy: [ @first ], queued: [ @first.id ]
  end

  test "free lowest ID namesake is woken without queuing the busy namesake" do
    assert_targets "@Echo", busy: [ @second ], immediate: [ @first.id ]
  end

  test "two busy namesakes still queue only the lowest ID" do
    assert_targets "@Echo", busy: [ @first, @second ], queued: [ @first.id ]
  end

  test "exact duplicate name across a guest and a local resident still selects one" do
    guest = accounts(:team_account).agents.create!(name: "Echo", system_prompt: "Test", runtime: "external")
    @account.guest_memberships.create!(agent: guest, added_by: users(:user_1))
    @chat.agents << guest

    assert_targets "@Echo", immediate: [ @first.id ]
    assert_targets "@Echo", busy: [ @first ], queued: [ @first.id ]
  end

  test "repeated mentions resolve each name once and retain mention order" do
    other = resident("Other")
    @chat.agents << other

    assert_targets "@Other, @echo and @ECHO", immediate: [ other.id, @first.id ]
  end

  test "ineligible lower ID namesake does not block an eligible resident" do
    [
      { active: false, runtime: "external" },
      { active: true, runtime: "deprecated" },
      { active: true, runtime: "provisioning" },
      { active: true, runtime: "inline" }
    ].each do |attributes|
      @first.update_columns(attributes)
      @chat.agents.reset

      assert_targets "@Echo", immediate: [ @second.id ]
      assert_targets "@Echo", busy: [ @second ], queued: [ @second.id ]
    end
  end

  test "all ineligible namesakes resolve neither an immediate nor queued target" do
    @first.update!(active: false)
    @second.update!(active: false)
    @chat.agents.reset

    assert_targets "@Echo", busy: [ @first, @second ]
  end

  test "an import awaiting approval does not capture the eligible namesake" do
    @chat.agents.load_target.replace([ @first, @second ])
    unapproved_import = Struct.new(:approval_error).new("Approval required")
    @first.stub(:github_resident_import, unapproved_import) do
      assert_targets "@Echo", immediate: [ @second.id ]
    end
  end

  test "paused offline residents remain eligible" do
    @first.update!(runtime: "offline", paused: true)
    @chat.agents.reset

    assert_targets "@Echo", immediate: [ @first.id ]
  end

  test "lower ID namesake outside the conversation cannot capture the mention" do
    @chat.agents.delete(@first)
    @chat.agents.reset

    assert_targets "@Echo", immediate: [ @second.id ]
    assert_targets "@Echo", busy: [ @second ], queued: [ @second.id ]
  end

  test "same named human does not capture a resident mention and humans alone are not targets" do
    user = @account.owner
    user.profile.update!(first_name: "Echo", last_name: "Person")
    @first.update!(name: "Echo Person")
    @second.update!(name: "eCHO pERSON")
    @chat.agents.reset

    assert_equal "Echo Person", user.display_name
    assert_targets "@Echo Person", immediate: [ @first.id ]
    @chat.agents.delete(@first, @second)
    @chat.agents.reset
    assert_targets "@Echo Person"
  end

  test "blank content and nonmanual chats have no immediate or queued mention targets" do
    [ nil, "", " " ].each do |content|
      assert_targets content, busy: [ @first ]
    end

    @chat.update!(manual_responses: false)
    assert_targets "@Echo", busy: [ @first ]
  end

  private

  def resident(name)
    @account.agents.create!(name: name, system_prompt: "Test", runtime: "external")
  end

  def assert_targets(content, busy: [], immediate: [], queued: [])
    busy_ids = busy.map(&:id)
    @chat.stub(:agent_response_active?, ->(agent) { busy_ids.include?(agent.id) }) do
      assert_equal immediate, @chat.mentioned_agent_ids(content)
      assert_equal queued, @chat.busy_mentioned_agents(content).map(&:id)
    end
  end

end
