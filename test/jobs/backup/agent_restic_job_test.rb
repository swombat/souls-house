require "test_helper"

class Backup::AgentResticJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
    @ok = Struct.new(:success?).new(true)
  end

  test "transcripts are checked inside the pause and reach only the backup command" do
    order = []
    commands = []
    quiesced = ->(_agent, &block) { order << :pause; block.call.tap { order << :resume } }
    transcripts = ->(_agent) { order << :transcripts; [ "--mount", "synthetic-transcripts" ] }
    summary = { message_type: "summary", snapshot_id: "abc123", total_bytes_processed: 7 }.to_json
    restic = ->(*command) { commands << command; [ command.include?("backup") ? summary : "", "", @ok ] }

    Backup::AgentRestic.stub(:docker_environment, []) do
      Backup::AgentRestic.stub(:backup_mounts, []) do
        Backup::AgentRestic.stub(:with_quiesced, quiesced) do
          Backup::AgentRestic.stub(:transcript_mounts, transcripts) do
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

    assert_equal %i[pause transcripts resume], order
    backup = commands.find { |command| command.include?("backup") }
    assert_includes backup, "synthetic-transcripts"
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

end
