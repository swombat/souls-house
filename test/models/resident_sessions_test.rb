require "test_helper"
require "action_cable/test_helper"

class ResidentSessionsTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @account = @lume.account
    @chat = @account.chats.create!(title: "Room", manual_responses: true, agents: [ @lume, @mira ])
  end

  test "nothing running is an empty map" do
    assert_equal({}, ResidentSessions.by_agent([ @lume, @mira ]))
  end

  test "runs are counted per resident by kind: chat, Telegram, and everything else" do
    start_run(@lume, "conversation", chat: @chat)
    start_run(@lume, "conversation", chat: @chat)
    start_run(@lume, "telegram")
    start_run(@lume, "wake")
    start_run(@lume, "memory_formation")
    start_run(@mira, "orientation")

    assert_equal({ chat: 2, telegram: 1, other: 2 }, ResidentSessions.by_agent([ @lume, @mira ]).fetch(@lume.to_param))
    assert_equal({ chat: 0, telegram: 0, other: 1 }, ResidentSessions.by_agent([ @lume, @mira ]).fetch(@mira.to_param))
    assert_equal [ @lume.to_param ], ResidentSessions.by_agent([ @lume ]).keys, "only the residents asked about"
  end

  test "finished, terminal and aged-out runs stop counting" do
    run = start_run(@lume, "conversation", chat: @chat)
    start_run(@lume, "wake", execution_state: "completed")
    start_run(@lume, "wake", finished_at: Time.current)
    aged = start_run(@lume, "wake", run_id: nil, execution_state: nil)
    assert_equal({ chat: 1, telegram: 0, other: 1 }, ResidentSessions.by_agent([ @lume ]).fetch(@lume.to_param))

    # No broadcast marks the end of an aged-out run; the window does.
    aged.update_columns(started_at: (AgentRuntimeInteraction::ACTIVE_WINDOW + 1.minute).ago)
    run.update!(execution_state: "completed", finished_at: Time.current)
    assert_equal({}, ResidentSessions.by_agent([ @lume ]))
  end

  test "site totals split the house server from cloud VMs; a resident without a placement is on the house" do
    AgentPlacement.where(agent: [ @lume, @mira ]).delete_all
    AgentPlacement.create!(agent: @mira, backend: "hetzner_cloud", state: "pending", kind: "birth")
    start_run(@lume, "conversation", chat: @chat)
    start_run(@lume, "telegram")
    start_run(@mira, "wake")

    totals = ResidentSessions.site_totals
    assert_equal({ chat: 1, telegram: 1, other: 1 }, totals[:all])
    assert_equal({ chat: 1, telegram: 1, other: 0 }, totals[:house])
    assert_equal({ chat: 0, telegram: 0, other: 1 }, totals[:vm])
  end

  test "a run starting or ending refreshes its resident's home account and the site stream, not on telemetry" do
    home = "ResidentSessions:#{@account.to_param}"
    run = nil
    assert_broadcast_on(home, action: "refresh") do
      assert_broadcast_on("ResidentSessions:all", action: "refresh") { run = start_run(@lume, "wake") }
    end
    assert_no_broadcasts(home) { run.update!(stdout: "diagnostic", input_tokens: 10) }
    assert_broadcast_on(home, action: "refresh") { run.update!(execution_state: "completed", finished_at: Time.current) }
  end

  test "a run in a guest room refreshes the resident's home account, not the room's" do
    host = agents(:other_account_agent)
    other = host.account
    assert_not_equal @account, other
    guest_chat = other.chats.create!(title: "Their room", manual_responses: true, agents: [ host ])
    assert_broadcast_on("ResidentSessions:#{@account.to_param}", action: "refresh") do
      assert_no_broadcasts("ResidentSessions:#{other.to_param}") do
        start_run(@lume, "conversation", chat: guest_chat)
      end
    end
    assert_equal 1, ResidentSessions.by_agent([ @lume ]).fetch(@lume.to_param)[:chat]
  end

  private

  def start_run(agent, trigger_kind, chat: nil, run_id: SecureRandom.uuid, execution_state: "running", finished_at: nil)
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: trigger_kind, started_at: Time.current,
      run_id: run_id, execution_state: execution_state, finished_at: finished_at
    )
  end

end
