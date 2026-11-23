require "test_helper"

class Backup::AgentResticJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    @ok = Struct.new(:success?).new(true)
  end

  test "transcripts are checked inside the pause and reach only the backup command" do
    order = []
    commands = []
    quiesced = ->(_agent, &block) { order << :pause; block.call.tap { order << :resume } }
    transcripts = ->(_agent) { order << :transcripts; [ "--mount", "synthetic-transcripts" ] }
    journal = ->(_agent, &block) { order << :journal; block.call([ "-v", "synthetic-journal:/data/chaos-db:ro" ], {}) }
    summary = { message_type: "summary", snapshot_id: "abc123", total_bytes_processed: 7 }.to_json
    restic = ->(*command) { commands << command; [ command.include?("backup") ? summary : "", "", @ok ] }

    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:backup_mounts, []) do
        Backup::AgentRestic.stub(:with_quiesced, quiesced) do
          Backup::AgentRestic.stub(:transcript_mounts, transcripts) do
            Backup::ChaosJournalDump.stub(:with_volume, journal) do
              Backup::Fit.stub(:new, ->(*, **) { Struct.new(:call).new(nil) }) do
                Open3.stub(:capture3, restic) do
                  snapshot = Backup::AgentResticJob.perform_now(@agent.id, force: true)
                  assert snapshot.ok
                end
              end
            end
          end
        end
      end
    end

    assert_equal %i[pause transcripts journal resume], order
    backup = commands.find { |command| command.include?("backup") }
    assert_includes backup, "synthetic-transcripts"
    assert_includes backup, "synthetic-journal:/data/chaos-db:ro"
    assert commands.reject { |command| command.include?("backup") }.none? { |command| command.include?("synthetic-transcripts") }
  end

  test "a refused transcript path is recorded with its reason" do
    refused = ->(_agent) { raise Backup::AgentRestic::TranscriptRefused, "Transcript path claude/projects has a link on it" }
    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:backup_mounts, []) do
        Backup::AgentRestic.stub(:with_quiesced, ->(_agent, &block) { block.call }) do
          Backup::AgentRestic.stub(:transcript_mounts, refused) do
            Open3.stub(:capture3, [ "", "", @ok ]) do
              assert_raises(Backup::AgentRestic::TranscriptRefused) do
                Backup::AgentResticJob.perform_now(@agent.id, force: true)
              end
            end
          end
        end
      end
    end

    snapshot = @agent.agent_backup_snapshots.order(:id).last
    assert_not snapshot.ok
    assert_match "claude/projects has a link", snapshot.stderr_tail
  end

  # Throwaway 50, 21 Nov 2026: its four volumes had been removed, and the
  # backup's `docker run -v` brought them all back empty.
  test "a missing volume is reported by name and never mounted, so never recreated" do
    names = Agents::Resources.new(@agent).volumes
    gone = [ names[:identity], names[:work] ]
    runs = []
    docker = lambda do |*command|
      if command[1..2] == %w[volume inspect]
        gone.include?(command.last) ? [ "", "Error: No such volume: #{command.last}", Struct.new(:success?).new(false) ] : [ "", "", @ok ]
      else
        runs << command
        [ "", "", @ok ]
      end
    end

    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:with_quiesced, ->(_agent, &block) { block.call }) do
        Open3.stub(:capture3, docker) do
          assert_raises(Backup::AgentRestic::SourceVolumeMissing) do
            Backup::AgentResticJob.perform_now(@agent.id, force: true)
          end
        end
      end
    end

    assert_equal "Backup failed: identity, work volumes missing; not recreated",
      @agent.agent_backup_snapshots.order(:id).last.stderr_tail
    assert runs.none? { |command| command.any? { |part| part.to_s.include?(names[:identity]) || part.to_s.include?(names[:work]) } },
      "no command after the check names a missing volume"
  end

  test "a Docker that cannot answer is recorded as that, not as a missing volume" do
    docker = lambda do |*command|
      command[1..2] == %w[volume inspect] ? [ "", "Cannot connect to the Docker daemon", Struct.new(:success?).new(false) ] : [ "", "", @ok ]
    end

    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:with_quiesced, ->(_agent, &block) { block.call }) do
        Open3.stub(:capture3, docker) do
          assert_raises(Backup::AgentRestic::SourceVolumeUnknown) { Backup::AgentResticJob.perform_now(@agent.id, force: true) }
        end
      end
    end
    assert_match "Cannot inspect the resident's identity volume", @agent.agent_backup_snapshots.order(:id).last.stderr_tail
  end

  test "only the backup command mounts the resident's volumes; init, forget and fit read the repository alone" do
    names = Agents::Resources.new(@agent).volumes.except(:state).values
    runs = []
    summary = { message_type: "summary", snapshot_id: "abc123", total_bytes_processed: 7 }.to_json
    docker = lambda do |*command|
      runs << command if command[1] == "run"
      [ command.include?("backup") ? summary : "", "", @ok ]
    end
    fit = ->(_agent, run:) { Struct.new(:call).new(nil).tap { run.call("stats") } }

    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:with_quiesced, ->(_agent, &block) { block.call }) do
        Backup::AgentRestic.stub(:transcript_mounts, []) do
          Backup::ChaosJournalDump.stub(:with_volume, ->(_agent, &block) { block.call([], nil) }) do
            Backup::Fit.stub(:new, fit) do
              Open3.stub(:capture3, docker) do
                assert Backup::AgentResticJob.perform_now(@agent.id, force: true).ok
              end
            end
          end
        end
      end
    end

    mounting = runs.select { |command| names.any? { |name| command.any? { |part| part.to_s.include?(name) } } }
    assert_equal 1, mounting.size
    assert_includes mounting.first, "backup"
    assert_includes runs.map { |command| command.find { |part| %w[init stats].include?(part) } }.compact, "init"
  end

  test "a resident retired after the job started is not backed up and leaves no row" do
    retire = lambda do |_agent, &block|
      @agent.update_columns(runtime: "deprecated", deprecation_reason: "#{Agents::RetireLocal::REASON_PREFIX}: test")
      block.call
    end
    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:with_quiesced, retire) do
        Open3.stub(:capture3, ->(*command) { command[1] == "run" && command.include?("backup") ? raise("backup reached") : [ "", "", @ok ] }) do
          assert_nil Backup::AgentResticJob.perform_now(@agent.id, force: true)
        end
      end
    end
    assert_empty @agent.agent_backup_snapshots
  end

end
