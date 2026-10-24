require "test_helper"

class RuntimeOomCheckJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", container_name: "hk-agent-oomtest", container_memory_mb: 8192
    )
    @chat = @agent.account.chats.create!(title: "OOM", manual_responses: true, agents: [ @agent ])
  end

  test "a failed, timed-out or lost run is checked; a completed or cancelled one is not" do
    %w[failed timed_out outcome_unknown].each do |state|
      assert_enqueued_with(job: RuntimeOomCheckJob) { running_run.finish_execution!(state) }
    end
    %w[completed cancelled busy].each do |state|
      assert_no_enqueued_jobs(only: RuntimeOomCheckJob) { running_run.finish_execution!(state) }
    end
  end

  test "kills during the run window make the run say it ran out of memory, keeping the runtime's error" do
    run = failed_run(error_class: "ClampRuntimeFailed", error_message: "transport closed")
    windows = []
    with_oom_kills(3, windows) { RuntimeOomCheckJob.perform_now(run.id) }

    run.reload
    assert run.ran_out_of_memory?
    assert_equal 3, run.container_oom_kills
    assert_equal "ClampRuntimeFailed", run.error_class
    assert_equal "transport closed", run.error_message
    assert_match(/\ARan out of memory: the kernel killed 3 processes .*limit 8192 MB/, run.out_of_memory_message)
    assert_equal run.out_of_memory_message, run.as_session_json[:out_of_memory_message]
    assert_equal [ [ run.started_at, run.finished_at ] ], windows
    assert_equal "ran out of memory", run.send(:chat_activity_status_label)
    assert_equal "ran out of memory", run.live_activity_json[:status_label]
  end

  test "no kills, or Docker unable to say, leaves the run as it was" do
    [ 0, nil ].each do |kills|
      run = failed_run(error_class: "ClampRuntimeFailed", error_message: "transport closed")
      with_oom_kills(kills) { RuntimeOomCheckJob.perform_now(run.id) }
      run.reload
      assert_nil run.container_oom_kills
      assert_nil run.out_of_memory_message
      assert_equal "finished with an error", run.send(:chat_activity_status_label)
    end
  end

  test "a queued check for a lost run that completed before the check runs does not query or write" do
    run = lost_run
    run.finish_execution!("completed")
    Agents::RuntimeLocation.stub(:local?, true) do
      Agents::Sandbox.stub(:new, ->(*) { flunk "Docker consulted for a completed run" }) do
        RuntimeOomCheckJob.perform_now(run.id)
      end
    end
    assert_nil run.reload.container_oom_kills
    assert_equal "finished", run.live_activity_json[:status_label]
  end

  test "a lost run that completes while the Docker query is running is not written" do
    run = lost_run
    completing = lambda do
      AgentRuntimeInteraction.find(run.id).finish_execution!("completed")
      2
    end
    with_oom_kills(completing) { RuntimeOomCheckJob.perform_now(run.id) }

    run.reload
    assert_equal "completed", run.execution_state
    assert_nil run.container_oom_kills
    assert_not run.ran_out_of_memory?
    assert_equal "finished", run.live_activity_json[:status_label]
  end

  test "a lost run whose window moved while the query ran is left to the check its new end enqueued" do
    run = lost_run
    moving = lambda do
      AgentRuntimeInteraction.find(run.id).finish_execution!("failed")
      2
    end
    assert_enqueued_with(job: RuntimeOomCheckJob, args: [ run.id ]) do
      with_oom_kills(moving) { RuntimeOomCheckJob.perform_now(run.id) }
    end
    assert_nil run.reload.container_oom_kills
  end

  test "a lost run that completes after the count was written says finished, not out of memory" do
    run = lost_run
    with_oom_kills(2) { RuntimeOomCheckJob.perform_now(run.id) }
    assert_equal "ran out of memory", run.reload.live_activity_json[:status_label]

    run.finish_execution!("completed")
    run.reload
    assert_equal 2, run.container_oom_kills
    assert_not run.ran_out_of_memory?
    assert_nil run.out_of_memory_message
    assert_equal "finished", run.live_activity_json[:status_label]
  end

  test "a resident placed on a VM is not checked against local Docker" do
    run = failed_run(error_class: "ClampRuntimeFailed", error_message: "transport closed")
    Agents::RuntimeLocation.stub(:local?, false) do
      Agents::Sandbox.stub(:new, ->(*) { flunk "local Docker consulted for a VM resident" }) do
        RuntimeOomCheckJob.perform_now(run.id)
      end
    end
    assert_equal "transport closed", run.reload.error_message
  end

  private

  def with_oom_kills(kills, windows = [], &block)
    sandbox = Object.new
    sandbox.define_singleton_method(:oom_kills_between) do |from, to|
      windows << [ from, to ]
      kills.respond_to?(:call) ? kills.call : kills
    end
    Agents::RuntimeLocation.stub(:local?, true) do
      Agents::Sandbox.stub(:new, sandbox, &block)
    end
  end

  def running_run
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{@chat.id}", started_at: Time.current, run_id: SecureRandom.uuid,
      execution_state: "running", execution_deadline_at: 10.minutes.from_now
    )
  end

  def lost_run
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{@chat.id}", started_at: 10.minutes.ago, run_id: SecureRandom.uuid,
      execution_state: "outcome_unknown", finished_at: 1.minute.ago
    )
  end

  def failed_run(**attrs)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{@chat.id}", started_at: 10.minutes.ago, run_id: SecureRandom.uuid,
      execution_state: "failed", finished_at: 1.minute.ago, **attrs
    )
  end

end

class SandboxOomKillsTest < ActiveSupport::TestCase

  setup do
    agent = agents(:research_assistant)
    agent.update!(container_name: "hk-agent-oomtest")
    @sandbox = Agents::Sandbox.new(agent)
  end

  test "asks Docker for the enclosing seconds and counts only events inside the run" do
    from = Time.at(1_791_620_000, 900_000, :usec)
    to = Time.at(1_791_620_001, 100_000, :usec)
    events = {
      before: 1_791_620_000_100_000_000,
      start: 1_791_620_000_900_000_000,
      inside: 1_791_620_001_000_000_000,
      end: 1_791_620_001_100_000_000,
      after: 1_791_620_001_900_000_000
    }
    calls = []
    stub_docker(events.values.join("\n") + "\n", calls)

    assert_equal 3, @sandbox.oom_kills_between(from, to)
    assert_equal [ "events", "--since", "1791620000", "--until", "1791620002",
      "--filter", "container=hk-agent-oomtest", "--filter", "event=oom", "--format", "{{.TimeNano}}" ], calls.first

    { before: 0, start: 1, inside: 1, end: 1, after: 0 }.each do |name, expected|
      stub_docker("#{events.fetch(name)}\n")
      assert_equal expected, @sandbox.oom_kills_between(from, to), "event at #{name}"
    end
  end

  test "a run read back from the database keeps its sub-second bounds" do
    run_start = Time.zone.parse("2026-10-10 12:00:00.900000")
    stub_docker("#{(run_start.to_r * 1_000_000_000).to_i - 1}\n#{(run_start.to_r * 1_000_000_000).to_i}\n")
    assert_equal 1, @sandbox.oom_kills_between(run_start, run_start + 1)
  end

  test "ignores blank or garbled lines, and is nil when Docker cannot answer" do
    stub_docker("\nnot-a-time\n1791620000500000000\n")
    assert_equal 1, @sandbox.oom_kills_between(Time.at(1_791_620_000), Time.at(1_791_620_001))

    @sandbox.define_singleton_method(:docker_capture) { |*| { stdout: "", stderr: "no docker", ok: false } }
    assert_nil @sandbox.oom_kills_between(Time.at(1_791_620_000), Time.at(1_791_620_001))
  end

  private

  def stub_docker(stdout, calls = [])
    @sandbox.define_singleton_method(:docker_capture) do |*args|
      calls << args
      { stdout: stdout, stderr: "", ok: true }
    end
  end

end
