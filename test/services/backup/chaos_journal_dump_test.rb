require "test_helper"

module Backup
  class ChaosJournalDumpTest < ActiveSupport::TestCase

    HOUSE = { host: "pg", username: "house", database: "house_db" }.freeze
    SERVER = { image: "pgimage:16", network: "kamal" }.freeze

    setup do
      @agent = agents(:research_assistant)
      @agent.uuid = "019f9dbd-4b8b-7c23-80be-770379e5581f"
    end

    test "reads the resident's database and its own role on the house server" do
      target = ChaosJournalDump.target_from(%(storage_url = "postgresql://res_main:s%40cret@pg:5432/res_main"\n), house: HOUSE)
      assert_equal [ "pg", 5432, "res_main", "s@cret", "res_main" ], target.to_a
    end

    test "a home on SQLite has nothing to dump" do
      assert_nil ChaosJournalDump.target_from(%(storage_url = "sqlite:///home/agent/.chaos/chaos.sqlite"), house: HOUSE)
    end

    test "anything else it cannot place fails closed" do
      [
        "",
        %(storage_url = "env:CHAOS_STORAGE_URL"),
        %(storage_url = "postgresql://r:p@elsewhere:5432/x_main"),
        %(storage_url = "postgresql://r:p@pg:5432/mira_pg_final_deep_oauth_20261111"),
        %(storage_url = "postgresql://r:p@pg:5432/house_db"),
        %(storage_url = "postgresql://r:p@pg:5432/x;drop"),
        %(storage_url = "postgresql://pg:5432/x_main"),
        %(storage_url = "postgresql://house:p@pg:5432/x_main")
      ].each do |line|
        assert_raises(ChaosJournalDump::Error, line) { ChaosJournalDump.target_from(line, house: HOUSE) }
      end
    end

    test "no chaos volume means no dump and no container" do
      commands = []
      Open3.stub(:capture3, ->(*command) { commands << command; [ "", "Error: No such volume", failed ] }) do
        ChaosJournalDump.with_volume(@agent) { |mounts, receipt| assert_equal [ [], nil ], [ mounts, receipt ] }
      end
      assert_equal 1, commands.size
    end

    test "a config without a readable storage line fails the backup instead of skipping the journal" do
      read = ->(*command) { command[1] == "run" ? [ "", "", failed ] : [ "", "", ok ] }
      ChaosJournalDump.stub(:house_config, HOUSE) do
        Open3.stub(:capture3, read) do
          assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.with_volume(@agent) { flunk "must not back up" } }
        end
      end
    end

    test "dumps as the resident's own role over the network, password by environment only, then verifies and removes" do
      calls = []
      list = "; Archive\n1; 0 0 TABLE public journal_entries u\n2; 0 0 TABLE DATA public journal_entries u\n"
      docker = lambda do |*args|
        env = args.first.is_a?(Hash) ? args.shift : {}
        calls << [ env, args ]
        out = if args.include?("grep") then %(storage_url = "postgresql://res_main:secret@pg:5432/res_main"\n)
        elsif args.include?("--list") then list
        else ""
        end
        [ out, "", ok ]
      end
      with_house { Open3.stub(:capture3, docker) do
        ChaosJournalDump.with_volume(@agent) do |mounts, receipt|
          assert_match %r{-chaos-db-\h{12}:/data/chaos-db:ro\z}, mounts.last
          assert_equal({ "toc_entries" => 2, "database" => "res_main" }, receipt)
        end
      end }

      env, dump = calls.find { |_, args| args.include?("pg_dump") }
      assert_equal({ "PGPASSWORD" => "secret" }, env)
      assert calls.none? { |_, args| args.any? { |part| part.include?("secret") } }, "the password is never in argv"
      assert_equal [ "--network", "kamal" ], dump[dump.index("--network"), 2]
      assert_includes dump.each_cons(2).to_a, [ "-U", "res_main" ]
      assert_includes dump.each_cons(2).to_a, [ "-h", "pg" ]
      assert_not_includes dump, "exec", "never inside the server's container, where loopback is trusted"
      assert_equal [ "docker", "volume", "rm" ], calls.last.last.first(3)
    end

    test "a role PostgreSQL refuses fails the backup and says so" do
      docker = lambda do |*args|
        args.shift if args.first.is_a?(Hash)
        if args.include?("grep") then [ %(storage_url = "postgresql://a_main:p@pg:5432/b_main"\n), "", ok ]
        elsif args.include?("pg_dump") then [ "", "pg_dump: error: permission denied for database b_main", failed ]
        else [ "", "", ok ]
        end
      end
      with_house { Open3.stub(:capture3, docker) do
        error = assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.with_volume(@agent) { flunk "must not back up" } }
        assert_match "role was refused", error.message
        assert_no_match "b_main", error.message
      end }
    end

    test "a dump without the journal in it fails the backup and the volume still goes" do
      removed = false
      docker = lambda do |*args|
        args.shift if args.first.is_a?(Hash)
        removed ||= args.first(3) == %w[docker volume rm]
        [ args.include?("grep") ? %(storage_url = "postgresql://r_main:p@pg:5432/r_main"\n) : "; empty\n", "", ok ]
      end
      with_house { Open3.stub(:capture3, docker) do
        assert_raises(ChaosJournalDump::Error) { ChaosJournalDump.with_volume(@agent) { flunk "must not back up" } }
      end }
      assert removed
    end

    private

    def with_house(&block)
      ChaosJournalDump.stub(:house_config, HOUSE) { ChaosJournalDump.stub(:server, SERVER, &block) }
    end

    def ok = Struct.new(:success?).new(true)
    def failed = Struct.new(:success?).new(false)

  end
end
