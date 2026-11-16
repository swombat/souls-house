require "test_helper"

module Backup
  class ChaosJournalDumpTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.uuid = "019f9dbd-4b8b-7c23-80be-770379e5581f"
    end

    test "reads the resident's own database on the house server" do
      line = %(storage_url = "postgresql://resident:secret@souls-house-postgres:5432/mira_pg_final_lume_main_20261111"\n)
      assert_equal "mira_pg_final_lume_main_20261111", ChaosJournalDump.database_from(line, house_host: "souls-house-postgres")
    end

    test "a home on SQLite, or on another server, has nothing to dump" do
      assert_nil ChaosJournalDump.database_from(%(storage_url = "sqlite:///home/agent/.chaos/chaos.sqlite"), house_host: "souls-house-postgres")
      assert_nil ChaosJournalDump.database_from(%(storage_url = "env:CHAOS_STORAGE_URL"), house_host: "souls-house-postgres")
      assert_nil ChaosJournalDump.database_from(%(storage_url = "postgresql://u:p@elsewhere:5432/x_main"), house_host: "souls-house-postgres")
      assert_nil ChaosJournalDump.database_from("", house_host: "souls-house-postgres")
    end

    test "never dumps a credential database, the house's own, or an odd name" do
      oauth = %(storage_url = "postgresql://u:p@pg:5432/mira_pg_final_deep_oauth_20261111")
      assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.database_from(oauth, house_host: "pg") }
      ChaosJournalDump.stub(:house_database, "souls_house_production") do
        house = %(storage_url = "postgresql://u:p@pg:5432/souls_house_production")
        assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.database_from(house, house_host: "pg") }
      end
      odd = %(storage_url = "postgresql://u:p@pg:5432/x;drop")
      assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.database_from(odd, house_host: "pg") }
    end

    test "no chaos volume means no dump and no container" do
      commands = []
      Open3.stub(:capture3, ->(*command) { commands << command; [ "", "Error: No such volume", failed ] }) do
        ChaosJournalDump.with_volume(@agent) { |mounts, receipt| assert_equal [ [], nil ], [ mounts, receipt ] }
      end
      assert_equal 1, commands.size
    end

    test "dumps through the server's own socket into a throwaway volume, verifies it and removes it" do
      commands = []
      pipelines = []
      line = %(storage_url = "postgresql://resident:secret@pg:5432/res_main"\n)
      capture = ->(*command) { commands << command; [ command.include?("sh") ? line : "", "", ok ] }
      pipeline = ->(*commands_, **) { pipelines << commands_; [ ok, ok ] }
      list = "; Archive\n1; 0 0 TABLE public journal_entries u\n2; 0 0 TABLE DATA public journal_entries u\n"
      pipeline_r = ->(*commands_, **, &block) { pipelines << commands_; block.call(StringIO.new(list), [ thread(ok), thread(ok) ]) }

      ChaosJournalDump.stub(:house_config, { host: "pg", username: "house", database: "house_db" }) do
        Open3.stub(:capture3, capture) do
          Open3.stub(:pipeline, pipeline) do
            Open3.stub(:pipeline_r, pipeline_r) do
              ChaosJournalDump.with_volume(@agent) do |mounts, receipt|
                assert_equal "-v", mounts.first
                assert_match %r{-chaos-db-\h{12}:/data/chaos-db:ro\z}, mounts.last
                assert_equal({ "toc_entries" => 2, "database" => "res_main" }, receipt)
              end
            end
          end
        end
      end

      dump = pipelines.first.first
      assert_equal [ "docker", "exec", "pg", "pg_dump", "-U", "house", "-Fc", "-Z0", "--no-owner", "--no-acl", "-d", "res_main" ], dump
      assert pipelines.flatten.none? { |part| part.include?("secret") }, "the resident's password is never passed"
      assert_equal [ "docker", "volume", "rm" ], commands.last.first(3)
    end

    test "a dump without the journal in it fails the backup" do
      line = %(storage_url = "postgresql://r:s@pg:5432/res_main"\n)
      removed = false
      capture = ->(*command) { removed ||= command.first(3) == %w[docker volume rm]; [ command.include?("sh") ? line : "", "", ok ] }
      pipeline_r = ->(*_c, **, &block) { block.call(StringIO.new("; empty\n"), [ thread(ok), thread(ok) ]) }
      ChaosJournalDump.stub(:house_config, { host: "pg", username: "house", database: "house_db" }) do
        Open3.stub(:capture3, capture) do
          Open3.stub(:pipeline, [ ok, ok ]) do
            Open3.stub(:pipeline_r, pipeline_r) do
              assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.with_volume(@agent) { flunk "must not back up" } }
            end
          end
        end
      end
      assert removed, "the dump volume is removed after a failure too"
    end

    test "a failed pg_dump fails the backup" do
      line = %(storage_url = "postgresql://r:s@pg:5432/res_main"\n)
      ChaosJournalDump.stub(:house_config, { host: "pg", username: "house", database: "house_db" }) do
        Open3.stub(:capture3, ->(*command) { [ command.include?("sh") ? line : "", "", ok ] }) do
          Open3.stub(:pipeline, [ failed, ok ]) do
            assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.with_volume(@agent) { flunk "must not back up" } }
          end
        end
      end
    end

    private

    def ok = Struct.new(:success?).new(true)
    def failed = Struct.new(:success?).new(false)
    def thread(status) = Struct.new(:value).new(status)

  end
end
