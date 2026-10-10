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

  test "kills during the run window turn the error into running out of memory" do
    run = failed_run(error_class: "ClampRuntimeFailed", error_message: "transport closed")
    windows = []
    with_oom_kills(3, windows) { RuntimeOomCheckJob.perform_now(run.id) }

    run.reload
    assert run.ran_out_of_memory?
    assert_equal "Agents::ContainerOutOfMemory", run.error_class
    assert_match(/\ARan out of memory: the kernel killed 3 processes .*limit 8192 MB/, run.error_message)
    assert_includes run.error_message, "ClampRuntimeFailed: transport closed"
    assert_equal [ [ run.started_at.to_i, run.finished_at.to_i ] ], windows.map { |from, to| [ from.to_i, to.to_i ] }
    assert_equal "ran out of memory", run.send(:chat_activity_status_label)
    assert_equal "ran out of memory", run.live_activity_json[:status_label]
  end

  test "no kills, or Docker unable to say, leaves the error as it was" do
    [ 0, nil ].each do |kills|
      run = failed_run(error_class: "ClampRuntimeFailed", error_message: "transport closed")
      with_oom_kills(kills) { RuntimeOomCheckJob.perform_now(run.id) }
      assert_equal "transport closed", run.reload.error_message
      assert_equal "finished with an error", run.send(:chat_activity_status_label)
    end
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
    sandbox.define_singleton_method(:oom_kills_between) { |from, to| windows << [ from, to ]; kills }
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

  def failed_run(**attrs)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{@chat.id}", started_at: 10.minutes.ago, run_id: SecureRandom.uuid,
      execution_state: "failed", finished_at: 1.minute.ago, **attrs
    )
  end

end

class SandboxOomKillsTest < ActiveSupport::TestCase

  test "counts Docker oom events for the container within the window" do
    agent = agents(:research_assistant)
    agent.update!(container_name: "hk-agent-oomtest")
    sandbox = Agents::Sandbox.new(agent)
    calls = []
    sandbox.define_singleton_method(:docker_capture) do |*args|
      calls << args
      { stdout: "1791620000\n1791620001\n", stderr: "", ok: true }
    end
    from, to = Time.at(1_791_619_000), Time.at(1_791_621_000)
    assert_equal 2, sandbox.oom_kills_between(from, to)
    assert_equal [ "events", "--since", "1791619000", "--until", "1791621001",
      "--filter", "container=hk-agent-oomtest", "--filter", "event=oom", "--format", "{{.Time}}" ], calls.first

    sandbox.define_singleton_method(:docker_capture) { |*| { stdout: "", stderr: "no docker", ok: false } }
    assert_nil sandbox.oom_kills_between(from, to)
  end

end
