require "test_helper"

module Agents
  class VmSeedTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(container_name: "hk-agent-seed-test")
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    end

    def answer(command, outcome, error: nil)
      command.deliver!(now: Time.current)
      command.record_result!({ "outcome" => outcome, "error" => error }.compact, now: Time.current)
    end

    test "issue! stores the exporter archive once and names it by digest" do
      command = VmSeed.new(@agent).issue!
      @placement.reload
      assert_equal "seed_home", command.kind
      assert_equal Digest::SHA256.hexdigest(@placement.seed_archive), @placement.seed_sha256
      payload = JSON.parse(command.payload_json)
      assert_equal({ "container_name" => "hk-agent-seed-test", "sha256" => @placement.seed_sha256,
                     "bytes" => @placement.seed_archive.bytesize }, payload)
      names = []
      Gem::Package::TarReader.new(StringIO.new(Zlib.gunzip(@placement.seed_archive))) { |tar| tar.each { |entry| names << entry.full_name } }
      assert_includes names, "soul.md"
    end

    test "issue! is idempotent while a seed is live, and reuses the same bytes after a failure" do
      first = VmSeed.new(@agent).issue!
      digest = @placement.reload.seed_sha256
      assert_equal first, VmSeed.new(@agent).issue!
      answer(first, "failed", error: "could not fetch seed archive: house answered 502")
      seed = VmSeed.new(@agent)
      assert seed.status.failed?
      assert seed.retryable?
      travel 1.minute do
        second = seed.issue!
        assert_not_equal first, second
        assert_equal digest, JSON.parse(second.payload_json)["sha256"]
        assert_equal digest, @placement.reload.seed_sha256
      end
    end

    test "status reports done, records seeded_at, and a done seed is not issued again" do
      command = VmSeed.new(@agent).issue!
      assert VmSeed.new(@agent).status.pending?
      answer(command, "done")
      status = VmSeed.new(@agent).status
      assert status.done?
      assert_equal 1, status.attempts
      assert @placement.reload.seeded_at
      assert_equal command, VmSeed.new(@agent).issue!
    end

    test "a refused or unknown seed is a failure that is not retryable" do
      %w[refused unknown].each do |outcome|
        RunnerCommand.where(agent_placement_id: @placement.id).delete_all
        answer(VmSeed.new(@agent).issue!, outcome, error: "identity volume is not empty and has no seed marker")
        seed = VmSeed.new(@agent)
        assert seed.status.failed?, outcome
        assert_not seed.retryable?, outcome
        assert_includes seed.status.error, outcome
      end
    end

    test "a new generation starts with no seed command" do
      VmSeed.new(@agent).issue!
      @placement.update!(generation: 2)
      assert VmSeed.new(@agent).status.none?
    end

    test "local placements and imported homes are refused" do
      @agent.stub(:imported_home?, true) do
        assert_raises(VmSeed::Unavailable) { VmSeed.new(@agent).issue! }
      end
      @placement.update!(backend: "local")
      assert_raises(VmSeed::Unavailable) { VmSeed.new(@agent).issue! }
      assert_equal 0, RunnerCommand.where(kind: "seed_home").count
    end

    test "an oversized archive is refused before anything is stored" do
      stub_const = VmSeed::MAX_BYTES
      VmSeed.send(:remove_const, :MAX_BYTES)
      VmSeed.const_set(:MAX_BYTES, 10)
      assert_raises(VmSeed::Unavailable) { VmSeed.new(@agent).issue! }
      assert_nil @placement.reload.seed_sha256
    ensure
      VmSeed.send(:remove_const, :MAX_BYTES)
      VmSeed.const_set(:MAX_BYTES, stub_const)
    end

  end
end
