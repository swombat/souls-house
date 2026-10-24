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

    def stage_import!(seed_roles: AgentImportStage::ROLES)
      @enrollment.update!(last_facts: { "seed_roles" => seed_roles }) if seed_roles
      @placement.update!(kind: "archive_import")
      AgentImportStage::ROLES.to_h do |role|
        bytes = Zlib.gzip("#{role} home")
        [ role, @agent.import_stages.create!(role:, archive: bytes, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize) ]
      end
    end

    test "an archive import seeds each role from its staged tarball and is done only when all three are" do
      stages = stage_import!
      issued = VmSeed.new(@agent).issue!
      assert_equal %w[identity repo work], issued.keys
      issued.each do |role, command|
        assert_equal({ "container_name" => "hk-agent-seed-test", "sha256" => stages[role].sha256,
                       "bytes" => stages[role].bytes, "role" => role }, JSON.parse(command.payload_json))
      end
      assert_nil @placement.reload.seed_archive
      assert_equal issued, VmSeed.new(@agent).issue!

      answer(issued["identity"], "done")
      answer(issued["repo"], "done")
      assert VmSeed.new(@agent).status.pending?
      assert_nil @placement.reload.seeded_at
      answer(issued["work"], "done")
      assert VmSeed.new(@agent).status.done?
      assert @placement.reload.seeded_at
    end

    test "a failed role is retried alone with the same bytes, and a refused role is not retryable" do
      stage_import!
      issued = VmSeed.new(@agent).issue!
      answer(issued["identity"], "done")
      answer(issued["repo"], "failed", error: "could not fetch seed archive: house answered 502")
      seed = VmSeed.new(@agent)
      assert seed.status.failed?
      assert_match(/\Arepo failed:/, seed.status.error)
      assert seed.retryable?
      again = seed.issue!
      assert_equal issued["identity"], again["identity"]
      assert_equal issued["work"], again["work"]
      assert_not_equal issued["repo"], again["repo"]
      assert_equal @agent.import_stages.find_by!(role: "repo").sha256, JSON.parse(again["repo"].payload_json)["sha256"]
      assert_equal "repo", again["repo"].seed_role
      assert_equal 2, VmSeed.new(@agent).status.attempts

      answer(again["work"], "refused", error: "work volume is not empty and has no seed marker")
      assert_not VmSeed.new(@agent).retryable?
    end

    test "a runner that has not said it seeds each role into its own volume gets no import seed at all" do
      # A runner from before roles ignores role and writes identity: an empty
      # identity volume would take the repo home, and identical digests would
      # report all three done with repo and work never written.
      [ nil, %w[identity], %w[identity repo] ].each do |roles|
        stage_import!(seed_roles: roles)
        @enrollment.update!(last_facts: {}) if roles.nil?
        error = assert_raises(VmSeed::Unavailable) { VmSeed.new(@agent).issue! }
        assert_match(/newer runner/, error.message)
        assert_equal 0, RunnerCommand.where(kind: "seed_home").count, roles.inspect
        @agent.import_stages.delete_all
      end
    end

    test "an archive import with a role missing from its stage is unavailable and queues nothing" do
      stage_import!
      @agent.import_stages.find_by!(role: "work").destroy!
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
