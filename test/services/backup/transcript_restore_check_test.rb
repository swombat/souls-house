require "test_helper"

class Backup::TranscriptRestoreCheckTest < ActiveSupport::TestCase

  ENV_KEYS = { "RESTIC_S3_BUCKET" => "bucket", "AWS_ACCESS_KEY_ID" => "id", "AWS_SECRET_ACCESS_KEY" => "secret",
    "AWS_REGION" => "eu-west-1" }.freeze

  setup do
    @saved_env = ENV_KEYS.keys.to_h { [ it, ENV[it] ] }
    ENV.update(ENV_KEYS)
    @agent = agents(:research_assistant)
    @agent.update!(uuid: SecureRandom.uuid_v7, restic_password: "pw")
    @snapshot = AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "a" * 64, taken_at: Time.current, ok: true)
    @marker = "claude/projects/-synthetic/969.jsonl"
  end

  teardown do
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def check(listing, expect: { @marker => "d" * 64 }, refuse: [ "decoy/969.txt" ], restore_ok: true)
    calls = []
    run = lambda do |argv|
      calls << argv
      if argv.include?("restore") then [ "", restore_ok ]
      elsif argv.include?("inventory") then [ listing, true ]
      else [ "", true ]
      end
    end
    [ Backup::TranscriptRestoreCheck.new(@agent, expect:, refuse:, run:).call, calls ]
  end

  test "an expected transcript that comes back with its digest, and nothing else under state, is ok" do
    report, calls = check(<<~OUT)
      F 120 ./#{@marker}
      F 30 ./antigravity/.chaos-conversations/map.json
      H #{"d" * 64} #{@marker}
      H - decoy/969.txt
    OUT

    assert report.ok?
    assert_equal({ present: true, ok: true }, report.expected[@marker])
    assert_equal({ "decoy/969.txt" => false }, report.refused)
    assert_equal({ files: 1, bytes: 120 }, report.by_path["claude/projects"])
    assert_equal 150, report.bytes
    restore = calls.find { it.include?("restore") }
    assert_equal [ "restore", "a" * 64, "--target", "/r", "--include", "/data/state" ], restore.last(6)
    assert_includes restore, "RESTIC_REPOSITORY=#{Backup::AgentRestic.repository_url(@agent)}"
    assert_equal [ "docker", "volume", "rm", "-f" ], calls.last.first(4), "the throwaway volume is removed"
  end

  test "a missing or altered transcript fails" do
    report, = check("H - #{@marker}\n")
    assert_not report.ok?
    assert_equal({ present: false, ok: false }, report.expected[@marker])

    report, = check("F 1 ./#{@marker}\nH #{"e" * 64} #{@marker}\n")
    assert_not report.ok?
    assert_equal({ present: true, ok: false }, report.expected[@marker])
  end

  test "anything under state outside the transcript paths fails, by path, and so does a refused path" do
    report, = check(<<~OUT)
      F 120 ./#{@marker}
      F 9 ./decoy/969.txt
      F 40 ./claude/.credentials.json
      H #{"d" * 64} #{@marker}
      H x decoy/969.txt
    OUT

    assert_not report.ok?
    assert_equal [ "claude/.credentials.json", "decoy/969.txt" ], report.outside
    assert report.refused["decoy/969.txt"]
  end

  test "a link in the restored state fails" do
    report, = check("F 120 ./#{@marker}\nL ./claude/projects/x\nH #{"d" * 64} #{@marker}\n")
    assert_not report.ok?
    assert_equal [ "claude/projects/x" ], report.links
  end

  test "a failed restore raises and still removes the throwaway volume" do
    calls = []
    run = ->(argv) { calls << argv; [ "", !argv.include?("restore") ] }
    assert_raises(Backup::TranscriptRestoreCheck::Failed) do
      Backup::TranscriptRestoreCheck.new(@agent, run:).call
    end
    assert_equal [ "docker", "volume", "rm", "-f" ], calls.last.first(4)
  end

  test "a resident with no verified backup is refused before docker is touched" do
    @snapshot.update!(ok: false)
    calls = []
    assert_raises(Backup::TranscriptRestoreCheck::Failed) do
      Backup::TranscriptRestoreCheck.new(@agent, run: ->(argv) { calls << argv; [ "", true ] }).call
    end
    assert_empty calls
  end

end
