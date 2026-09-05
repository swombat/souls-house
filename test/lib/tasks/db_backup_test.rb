require "test_helper"
require "rake"
include Rake::DSL
load Rails.root.join("lib/tasks/db_backup.rake")

class DbBackupTest < ActiveJob::TestCase

  test "finds the latest database backup across every S3 listing page" do
    first_page = BackupPage.new(
      [ BackupObject.new("helix_kit_production_2026-06-08_04-00-00.sql.gz") ],
      true,
      "page-2"
    )
    second_page = BackupPage.new(
      [
        BackupObject.new("agents/unrelated-snapshot"),
        BackupObject.new("helix_kit_production_2026-08-09_13-23-17.sql.gz")
      ],
      false,
      nil
    )
    client = PaginatedBackupClient.new(first_page, second_page)

    DbBackupHelpers.stub(:s3_client, client) do
      DbBackupHelpers.stub(:bucket_name, "backups") do
        assert_equal(
          "helix_kit_production_2026-08-09_13-23-17.sql.gz",
          DbBackupHelpers.latest_backup_key
        )
      end
    end

    assert_equal [ nil, "page-2" ], client.continuation_tokens
  end

  test "selects a downloaded backup by its timestamped filename rather than mtime" do
    Dir.mktmpdir do |directory|
      old_backup = File.join(directory, "helix_kit_production_2026-06-08_04-00-00.sql")
      new_backup = File.join(directory, "helix_kit_production_2026-08-09_13-23-17.sql")
      FileUtils.touch(new_backup, mtime: 1.day.ago.to_time)
      FileUtils.touch(old_backup, mtime: Time.current.to_time)

      DbBackupHelpers.stub(:download_path, Pathname(directory)) do
        assert_equal new_backup, DbBackupHelpers.latest_downloaded_sql
      end
    end
  end

  test "creates missing Chaos test agents without replacing deprecated residents" do
    account = accounts(:team_account)
    legacy_agent = account.agents.create!(
      name: "Claude Test Agent",
      system_prompt: "Legacy inline test agent",
      model_id: "anthropic/claude-sonnet-4.5",
      runtime: "deprecated"
    )

    Account.stub(:decode_id, account.id) do
      assert_difference "Agent.count", 3 do
        assert_difference "ApiKey.count", 3 do
          assert_enqueued_jobs 3, only: ProvisionAgentJob do
            capture_io { DbBackupHelpers.create_test_agents! }
          end
        end
      end
    end

    assert_equal "deprecated", legacy_agent.reload.runtime
    assert_equal "Legacy inline test agent", legacy_agent.system_prompt

    agents = account.agents.where(name: [
      "GPT Test Agent",
      "Grok Test Agent",
      "Gemini Test Agent"
    ])
    assert_equal 3, agents.count
    assert agents.all?(&:born_hosted?)
    assert agents.all?(&:provisioning?)
    assert agents.all? { |agent| agent.enabled_tools.empty? }
    assert agents.all? { |agent| agent.outbound_api_key.present? }
    assert agents.all? { |agent| agent.trigger_bearer_token.present? }
    assert_equal(
      {
        "GPT Test Agent" => "openai/gpt-5.6-luna",
        "Grok Test Agent" => "x-ai/grok-build-0.1",
        "Gemini Test Agent" => "google/gemini-3.7-flash"
      },
      agents.pluck(:name, :model_id).to_h
    )
  end

  BackupObject = Struct.new(:key)
  BackupPage = Struct.new(:contents, :is_truncated, :next_continuation_token)

  class PaginatedBackupClient

    attr_reader :continuation_tokens

    def initialize(*pages)
      @pages = pages
      @continuation_tokens = []
    end

    def list_objects_v2(bucket:, continuation_token: nil)
      continuation_tokens << continuation_token
      pages.fetch(continuation_token ? 1 : 0)
    end

    private

    attr_reader :pages

  end

end
