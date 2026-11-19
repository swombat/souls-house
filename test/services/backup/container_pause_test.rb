require "test_helper"

module Backup
  class ContainerPauseTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, container_name: "resident-container-pause-test")
    end

    test "Docker's answer is read as running, paused or stopped, and anything else as unknown" do
      { "true false" => :running, "true true" => :paused, "false false" => :stopped, "weird" => :unknown }.each do |out, state|
        ContainerPause.stub(:capture, ->(*) { [ out, "", ok ] }) { assert_equal state, ContainerPause.state(@agent), out }
      end
      ContainerPause.stub(:capture, ->(*) { [ "", "No such object", failed ] }) { assert_equal :unknown, ContainerPause.state(@agent) }
      ContainerPause.stub(:capture, ->(*) { raise Agents::BoundedCommand::TimedOut }) { assert_equal :unknown, ContainerPause.state(@agent) }
    end

    test "Docker not answering before the second try is unknown, and reported" do
      assert_error_reported(ContainerPause::StillPaused) do
        ContainerPause.stub(:capture, ->(*) { [ "", "timed out", failed ] }) do
          assert_equal :unknown, ContainerPause.retry_unpause!(@agent)
        end
      end
    end

    test "an unpause Docker accepts but that leaves the container paused counts as failed" do
      calls = 0
      fake = ->(*args) { calls += 1; args[1] == "unpause" ? [ "", "", ok ] : [ "true true", "", ok ] }
      assert_error_reported(ContainerPause::StillPaused) do
        ContainerPause.stub(:capture, fake) { assert_equal :still_paused, ContainerPause.retry_unpause!(@agent) }
      end
      assert_equal 3, calls
    end

    private

    def ok = Struct.new(:success?).new(true)
    def failed = Struct.new(:success?).new(false)

  end
end
