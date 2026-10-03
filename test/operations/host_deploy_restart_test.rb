require "test_helper"
require "open3"

class HostDeployRestartTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(container_name: "fixture", container_image: "fixture:old")
    @previous_env = ENV.to_h.slice("DEPLOY_RESIDENT_ID", "DEPLOY_RESIDENT_IMAGE", "DEPLOY_CHAOS_VERSION")
    ENV["DEPLOY_RESIDENT_ID"] = @agent.id.to_s
    ENV["DEPLOY_RESIDENT_IMAGE"] = "fixture:new"
    ENV["DEPLOY_CHAOS_VERSION"] = "chaos 47.10.0"
    @success = Struct.new(:success?, :exitstatus).new(true, 0)
    @idle = Struct.new(:success?, :exitstatus).new(false, 1)
    @mounts = [{ "Type" => "volume", "Name" => "fixture", "Source" => "/fixture", "Destination" => "/home/agent" }].to_json
  end

  teardown do
    %w[DEPLOY_RESIDENT_ID DEPLOY_RESIDENT_IMAGE DEPLOY_CHAOS_VERSION].each do |key|
      @previous_env.key?(key) ? ENV[key] = @previous_env[key] : ENV.delete(key)
    end
  end

  def run_script
    output, = capture_io { load Rails.root.join("ops/deploy/roll-resident.rb") }
    JSON.parse(output.lines.last)
  end

  def docker_idle_and_mounts(&block)
    capture = ->(*args) {
      case args
      when ["docker", "exec", "fixture", "pgrep", "-x", "chaos"] then ["", "", @idle]
      when ["docker", "inspect", "--format", "{{json .Mounts}}", "fixture"] then [@mounts, "", @success]
      when ["docker", "exec", "fixture", "chaos", "--version"] then ["chaos 47.10.0\n", "", @success]
      else raise "Unexpected Docker call"
      end
    }
    Open3.stub(:capture3, capture, &block)
  end

  test "pending turns leave resident and queue unchanged" do
    interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake",
      session_id: "fixture-session", started_at: Time.current, endpoint_url: "https://runtime.example.test")
    turn = ResidentTurn.enqueue!(interaction, {session_id: "fixture-session"})
    Agents::Sandbox.stub(:new, ->(*) { flunk "Busy resident must not restart" }) do
      assert_equal "busy", run_script.fetch("result")
    end
    assert_equal "queued", turn.reload.state
    assert_equal "fixture:old", @agent.reload.container_image
    assert @agent.active?
  end

  test "healthy recreation preserves originally inactive availability" do
    @agent.update!(active: false, paused: true)
    sandbox = Minitest::Mock.new
    sandbox.expect(:recreate!, true)
    client = Minitest::Mock.new
    client.expect(:turn_status, {status: 404, body: {"ledger_id" => "fixture"}}, [String])
    docker_idle_and_mounts do
      Agents::Sandbox.stub(:new, sandbox) do
        Agents::Endpoint.stub(:url_for, "https://runtime.example.test") do
          ChaosTriggerClient.stub(:new, client) do
            assert_equal "healthy", run_script.fetch("result")
          end
        end
      end
    end
    sandbox.verify
    client.verify
    assert_equal "fixture:new", @agent.reload.container_image
    assert_not @agent.active?
    assert @agent.paused?
  end

  test "failed recreation leaves a visible hold not a silent rollback" do
    sandbox = Object.new
    def sandbox.recreate! = raise("fixture failure")
    docker_idle_and_mounts do
      Agents::Sandbox.stub(:new, sandbox) do
        assert_raises(RuntimeError) { run_script }
      end
    end
    assert_not @agent.reload.active?
    assert @agent.paused?
    assert_equal "fixture:old", @agent.container_image
  end

end
