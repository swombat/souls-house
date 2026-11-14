require "test_helper"

# A run says when the resident's expected Chaos hooks were missing or didn't
# fire (jaMBVj). 12 Nov 2026: a storage move dropped Lume's hook rows and Lume
# woke without the wake hook for 14 hours while it felt whole from inside.
class HookPresenceTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(hook_expectations: {})
    @chat = @agent.account.chats.create!(manual_responses: true, agents: [ @agent ])
  end

  test "the first run that sees a working hook records the expectation as observed, and warns about nothing" do
    run = finish(hooks: inventory(%w[session_start before_turn stop]))

    assert_nil run.reload.hook_warning
    assert_equal %w[before_turn session_start stop], @agent.reload.hook_expectations.keys.sort
    assert_equal "observed", @agent.hook_expectations.dig("session_start", "source")
    assert_equal "expected", @agent.hook_expectations.dig("session_start", "state")
    assert_equal [ "house-session_start" ], @agent.hook_expectations.dig("session_start", "hook_ids")
  end

  test "the 12 Nov case: hooks gone from the store warn plainly, on every expected event" do
    finish(hooks: inventory(%w[session_start before_turn stop]))
    run = finish(hooks: inventory([]))

    assert_equal "Chaos hooks: no wake (session_start) hook is configured; no before_turn hook is configured; " \
                 "no stop hook is configured.", run.reload.hook_warning
  end

  test "an empty store with no expectation is not a warning (a hook that is absent isn't automatically broken)" do
    run = finish(hooks: inventory([]))

    assert_nil run.reload.hook_warning
    assert_equal({}, @agent.reload.hook_expectations)
  end

  test "a removal acknowledged off stops warning, and expected again brings it back" do
    expect_all
    @agent.set_hook_expectation!("session_start", "off", source: "owner")
    run = finish(hooks: inventory(%w[before_turn stop]))
    assert_nil run.reload.hook_warning
    assert_equal "owner", @agent.reload.hook_expectations.dig("session_start", "source")

    @agent.set_hook_expectation!("session_start", "expected", source: "resident")
    run = finish(hooks: inventory(%w[before_turn stop]))
    assert_equal "Chaos hooks: no wake (session_start) hook is configured.", run.reload.hook_warning
    assert_nil @agent.reload.hook_expectations.dig("session_start", "hook_ids"),
               "an owner/resident setting starts afresh rather than inheriting ids"
  end

  test "an off expectation is not overwritten by a later observation" do
    @agent.set_hook_expectation!("stop", "off", source: "resident")
    finish(hooks: inventory(%w[stop]))

    assert_equal "off", @agent.reload.hook_expectations.dig("stop", "state")
  end

  test "disabled, unapproved and inactive hooks each say so" do
    finish(hooks: inventory([]).merge("hooks" => [ hook("w", "session_start"), hook("b", "before_turn"), hook("s", "stop") ]))
    hooks = inventory([]).merge("hooks" => [
      hook("w", "session_start", enabled: false),
      hook("b", "before_turn", approved: false),
      hook("s", "stop", inactive_reason: "project is not trusted")
    ])
    run = finish(hooks: hooks)

    assert_equal "Chaos hooks: the wake (session_start) hook w is disabled; the before_turn hook b is not approved; " \
                 "the stop hook s is inactive (project is not trusted).", run.reload.hook_warning
  end

  test "an expectation set by hand with no hook ever seen working says what is wrong at the event level" do
    expect_all
    run = finish(hooks: inventory([]).merge("hooks" => [ hook("w", "session_start", enabled: false),
                                                          hook("b", "before_turn", approved: false),
                                                          hook("s", "stop", inactive_reason: "project is not trusted") ]))
    assert_equal "Chaos hooks: the wake (session_start) hook is disabled; the before_turn hook is not approved; " \
                 "the stop hook is inactive (project is not trusted).", run.reload.hook_warning
  end

  test "a failure to list the hooks is a warning only when something is expected" do
    run = finish(hooks: { "status" => "unavailable", "reason" => "chaos hooks list timed out" })
    assert_nil run.reload.hook_warning

    @agent.set_hook_expectation!("session_start", "expected", source: "owner")
    run = finish(hooks: { "status" => "unavailable", "reason" => "chaos hooks list timed out" })
    assert_equal "Chaos hooks: couldn't check the wake (session_start) hook (chaos hooks list timed out).", run.reload.hook_warning
  end

  test "without hook events from Chaos, firing is unknown and never assumed" do
    expect_all
    run = finish(hooks: inventory(%w[session_start before_turn stop]), outcome: "fresh")

    assert_nil run.reload.hook_warning
  end

  test "session_start is due on every exec, resumed too (Chaos dispatches it with source resume)" do
    expect_all
    fired = [ ran("before_turn"), ran("stop") ]
    resumed = finish(hooks: inventory(%w[session_start before_turn stop], runs: fired), outcome: "resumed")
    assert_equal "Chaos hooks: the wake (session_start) hook house-session_start didn't fire.", resumed.reload.hook_warning

    woke = finish(hooks: inventory(%w[session_start before_turn stop], runs: fired + [ ran("session_start") ]), outcome: "resumed")
    assert_nil woke.reload.hook_warning
  end

  test "a session_start failure on a resumed run is reported (Mira's reproduction)" do
    expect_all
    run = finish(hooks: inventory(%w[session_start before_turn stop],
                                  runs: [ ran("session_start", "failed"), ran("before_turn"), ran("stop") ]), outcome: "resumed")
    assert_equal "Chaos hooks: the wake (session_start) hook house-session_start failed.", run.reload.hook_warning
  end

  test "a healthy neighbouring hook never masks one that failed or didn't fire (Mira's reproductions)" do
    hooks = inventory(%w[session_start stop]).merge("hooks" => inventory(%w[session_start stop])["hooks"] +
      [ hook("identity", "before_turn"), hook("other", "before_turn") ])
    expect_all

    failed = finish(hooks: hooks.merge("runs_reported" => true, "runs" => [
      ran("session_start"), ran("stop"),
      { "id" => "identity", "event" => "before_turn", "status" => "failed" },
      { "id" => "other", "event" => "before_turn", "status" => "completed" }
    ]))
    assert_equal "Chaos hooks: the before_turn hook identity failed.", failed.reload.hook_warning

    silent = finish(hooks: hooks.merge("runs_reported" => true, "runs" => [
      ran("session_start"), ran("stop"), { "id" => "other", "event" => "before_turn", "status" => "completed" }
    ]))
    assert_equal "Chaos hooks: the before_turn hook identity didn't fire.", silent.reload.hook_warning
  end

  test "a hook seen running before that is now gone is named even while another hook covers the event" do
    finish(hooks: inventory([]).merge("hooks" => [ hook("wake", "session_start"), hook("extra", "session_start") ]))
    run = finish(hooks: inventory([]).merge("hooks" => [ hook("extra", "session_start") ]))

    assert_equal "Chaos hooks: the wake (session_start) hook wake is gone.", run.reload.hook_warning
  end

  test "a conditional hook is never accused of not firing, but its failure still counts" do
    expect_all
    hooks = inventory(%w[before_turn stop]).merge("runs_reported" => true)
    hooks["hooks"] << hook("only-on-startup", "session_start", has_matcher: true)
    quiet = finish(hooks: hooks.merge("runs" => [ ran("before_turn"), ran("stop") ]))
    assert_nil quiet.reload.hook_warning

    failed = finish(hooks: hooks.merge("runs" => [ ran("before_turn"), ran("stop"),
      { "id" => "only-on-startup", "event" => "session_start", "status" => "failed" } ]))
    assert_equal "Chaos hooks: the wake (session_start) hook only-on-startup failed.", failed.reload.hook_warning
  end

  test "a stop hook is only expected to fire when the turn finished" do
    expect_all
    failed = finish(hooks: inventory(%w[session_start before_turn stop], runs: [ ran("session_start"), ran("before_turn") ]),
                    outcome: "resumed", status: "error", returncode: 1)
    assert_nil failed.reload.hook_warning
  end

  test "a hook that ran and failed says how it ended" do
    expect_all
    run = finish(hooks: inventory(%w[session_start before_turn stop],
                                  runs: [ ran("session_start", "failed"), ran("before_turn"), ran("stop") ]), outcome: "fresh")

    assert_equal "Chaos hooks: the wake (session_start) hook house-session_start failed.", run.reload.hook_warning
  end

  test "no report (an older shim) changes nothing" do
    expect_all
    run = finish(hooks: nil)

    assert_nil run.reload.hook_warning
  end

  test "the check never stands between a run and its result" do
    HookPresence.stub(:evaluate!, ->(_interaction) { raise "boom" }) do
      run = finish(hooks: inventory([]))
      assert_equal "ok", run.reload.runtime_status
    end
  end

  test "unknown events, states and sources are refused" do
    assert_raises(ArgumentError) { @agent.set_hook_expectation!("pre_compact", "off", source: "owner") }
    assert_raises(ArgumentError) { @agent.set_hook_expectation!("stop", "maybe", source: "owner") }
    assert_raises(ArgumentError) { @agent.set_hook_expectation!("stop", "off", source: "someone") }
  end

  private

  def expect_all
    HookPresence::EVENTS.each { |event| @agent.set_hook_expectation!(event, "expected", source: "observed") }
  end

  def hook(id, event, enabled: true, approved: true, inactive_reason: nil, has_matcher: false)
    { "id" => id, "event" => event, "enabled" => enabled, "approved" => approved,
      "inactive_reason" => inactive_reason, "project_scoped" => true, "has_matcher" => has_matcher }
  end

  def inventory(events, runs: nil)
    {
      "status" => "ok",
      "hooks" => events.map { |event| hook("house-#{event}", event) },
      "runs_reported" => !runs.nil?,
      "runs" => runs || []
    }
  end

  def ran(event, status = "completed")
    { "id" => "house-#{event}", "event" => event, "status" => status }
  end

  def finish(hooks:, outcome: "resumed", status: "ok", returncode: 0)
    run = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "manual",
      session_id: "s-#{SecureRandom.hex(4)}", endpoint_url: "https://runtime.example.test", started_at: Time.current)
    telemetry = { "schema_version" => 1, "session" => { "outcome" => outcome } }
    telemetry["hooks"] = hooks if hooks
    run.record_result!(status: status == "ok" ? 200 : 500,
                       body: { "status" => status, "returncode" => returncode, "telemetry" => telemetry })
    run
  end

end
