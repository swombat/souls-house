require "test_helper"

class AgentRuntimeInteraction::StatusPresenceTest < ActiveSupport::TestCase

  Presence = AgentRuntimeInteraction::StatusPresence

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Status creatures", manual_responses: true, agents: [ @agent ])
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    @run.claim_dispatch!
    @run.activity_configuration!
  end

  def stage(state, waking: false, health: "live", exit_unconfirmed: false, out_of_memory: false, fallback: false)
    Presence.stage_for(state:, waking:, health:, exit_unconfirmed:, out_of_memory:, fallback:)
  end

  test "three stages get a creature; every other state keeps its plain words" do
    assert_equal "arriving", stage("preparing", health: "connecting")
    assert_equal "arriving", stage("running", waking: true)
    assert_equal "arriving", stage("running", health: "connecting")
    assert_equal "here", stage("running")
    assert_equal "settled", stage("completed")
    %w[queued failed timed_out cancelled busy outcome_unknown].each { |state| assert_nil stage(state), state }
    assert_nil stage("running", health: "stale")
    assert_nil stage("running", exit_unconfirmed: true)
    assert_nil stage("completed", out_of_memory: true)
    assert_nil stage("running", fallback: true)
  end

  test "family and phrase are steady for a run and a stage" do
    first = Presence.presentation(run_id: "run-a", stage: "here", replied: false)
    assert_equal first, Presence.presentation(run_id: "run-a", stage: "here", replied: false)
    assert_includes Presence::FAMILIES, first[:status_creature]
    assert_includes Presence::PHRASES["here"], first[:status_phrase]
    assert_equal "is working", first[:status_plain]
    assert_equal first[:status_creature], Presence.presentation(run_id: "run-a", stage: "settled", replied: true)[:status_creature]
  end

  test "the server picks only families the card can draw" do
    drawn = Rails.root.join("app/frontend/lib/status-creatures.js").read.scan(/^  (\w+): \{$/).flatten
    assert_equal Presence::FAMILIES.sort, drawn.sort
  end

  test "every family is reachable and the silly phrase is rare" do
    runs = (1..2000).map { |n| "run-#{n}" }
    assert_equal Presence::FAMILIES.sort, runs.map { |id| Presence.presentation(run_id: id, stage: "here", replied: false)[:status_creature] }.uniq.sort
    silly = runs.count { |id| Presence.phrase(id, "arriving") == Presence::PHRASES["arriving"].last }
    assert_in_delta 200, silly, 60
  end

  test "said their piece only follows a linked reply" do
    runs = (1..2000).map { |n| "quiet-#{n}" }
    assert(runs.none? { |id| Presence.phrase(id, "settled", replied: false) == "said their piece" })
    assert(runs.any? { |id| Presence.phrase(id, "settled", replied: true) == "said their piece" })
  end

  test "the activity projection carries the new fields beside an untouched status label" do
    @run.update!(execution_state: "running")
    @run.agent_runtime_attempts.create!(attempt_id: SecureRandom.uuid, number: 1, last_report_at: Time.current)
    json = @run.as_chat_activity_json
    assert_equal "is working", json[:status_label]
    assert_equal "here", json[:status_stage]
    assert_includes Presence::FAMILIES, json[:status_creature]
    assert_includes Presence::PHRASES["here"], json[:status_phrase]

    @run.finish_execution!("failed")
    json = @run.as_chat_activity_json
    assert_equal "finished with an error", json[:status_label]
    assert_nil json[:status_stage]
    assert_nil json[:status_creature]
    assert_nil json[:status_phrase]
  end

  test "a quiet finish settles without claiming it said anything" do
    @run.update!(execution_state: "running")
    @run.finish_execution!("completed")
    json = @run.as_chat_activity_json
    assert_equal "finished", json[:status_label]
    assert_equal "settled", json[:status_stage]
    assert_equal "No linked reply", json[:reply_label]
    assert_not_equal "said their piece", json[:status_phrase]
  end

end
