require "test_helper"

class Backup::TranscriptRestoreCheckTest < ActiveSupport::TestCase

  ENV_KEYS = { "RESTIC_S3_BUCKET" => "bucket", "AWS_ACCESS_KEY_ID" => "id", "AWS_SECRET_ACCESS_KEY" => "secret",
    "AWS_REGION" => "eu-west-1" }.freeze
  MARKER = "claude/projects/-synthetic/969.jsonl".freeze
  BODY = "{\"synthetic\":true}\n".freeze
  DIGEST = Digest::SHA256.hexdigest(BODY)

  setup do
    @saved_env = ENV_KEYS.keys.to_h { [ it, ENV[it] ] }
    ENV.update(ENV_KEYS)
    @agent = agents(:research_assistant)
    @agent.update!(uuid: SecureRandom.uuid_v7, restic_password: "pw")
    @snapshot = AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "a" * 64, taken_at: Time.current, ok: true)
    @root = Dir.mktmpdir("restored-state")
  end

  teardown do
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@root)
  end

  def put(path, content = BODY)
    FileUtils.mkdir_p(File.join(@root, File.dirname(path)))
    File.write(File.join(@root, path), content)
  end

  # Docker stand-in: the restore and removals succeed (unless told not to),
  # and the inventory is the real shell script run over @root.
  def runner(calls, rm_ok: true, restore_ok: true, inventory: nil, ps_out: "")
    lambda do |argv|
      calls << argv
      if argv.include?("inventory")
        next [ inventory, true ] if inventory

        args = argv.drop(argv.index("inventory") + 1)
        out, _err, status = Open3.capture3({ "ROOT" => @root }, "sh", "-c", Backup::TranscriptRestoreCheck::INVENTORY,
          "inventory", *args)
        [ out, status.success? ]
      elsif argv.include?("restore") then [ "", restore_ok ]
      elsif argv[1, 2] == %w[volume rm] then [ "", rm_ok ]
      elsif argv[1] == "ps" then [ ps_out, true ]
      else [ "", true ]
      end
    end
  end

  def inventory(*paths)
    out, _err, status = Open3.capture3({ "ROOT" => @root }, "sh", "-c", Backup::TranscriptRestoreCheck::INVENTORY,
      "inventory", *paths)
    assert status.success?
    out.lines.map(&:chomp)
  end

  def check(expect: { MARKER => DIGEST }, refuse: [], **options)
    calls = []
    report = Backup::TranscriptRestoreCheck.new(@agent, expect:, refuse:, run: runner(calls, **options)).call
    [ report, calls ]
  end

  test "an expected synthetic transcript that comes back with its digest is recovered" do
    put(MARKER)
    report, calls = check

    assert report.ok?
    assert_equal "recovered", report.verdict
    assert_equal({ state: "match", ok: true }, report.expected[MARKER])
    assert_equal({ files: 1, bytes: BODY.bytesize }, report.by_path["claude/projects"])
    restore = calls.find { it.include?("restore") }
    assert_equal [ "restore", "a" * 64, "--target", "/r", "--include", "/data/state" ], restore.last(6)
    assert_includes restore, "--name"
    assert(calls.any? { it[1, 2] == %w[volume rm] }, "the throwaway volume is removed")
    assert_equal 2, calls.count { it[1, 2] == %w[rm -f] }, "both named tool containers are removed"
  end

  test "a missing, altered or linked expected file fails, and a linked one is never hashed" do
    report, = check
    assert_equal({ state: "absent", ok: false }, report.expected[MARKER])
    assert_equal "failed", report.verdict
    assert_not report.ok?

    put(MARKER, "different\n")
    report, = check
    assert_equal({ state: "different", ok: false }, report.expected[MARKER])

    FileUtils.rm_rf(File.join(@root, "claude/projects/-synthetic"))
    put("elsewhere/969.jsonl")
    File.symlink(File.join(@root, "elsewhere"), File.join(@root, "claude/projects/-synthetic"))
    report, = check
    assert_equal({ state: "link", ok: false }, report.expected[MARKER])
    assert_equal 1, report.link_count
    assert_equal 1, report.outside_count
  end

  test "REFUSE is checked from the listing: a present decoy fails without being opened" do
    put(MARKER)
    put("decoy/secret.txt", "never read\n")
    report, calls = check(refuse: [ "decoy/secret.txt", "decoy-absent" ])

    assert_equal({ "decoy/secret.txt" => true, "decoy-absent" => false }, report.refused)
    assert_equal "failed", report.verdict
    assert_equal 1, report.outside_count
    inventory = calls.find { it.include?("inventory") }
    assert_not_includes inventory, "decoy/secret.txt", "a refused path is never handed to sha256sum"
    assert_not_includes report.to_h.to_json, "never read"
  end

  test "an empty restored state is not a pass" do
    report, = check
    assert_equal "failed", report.verdict
    assert_equal 0, report.files
  end

  test "an incomplete or unreadable inventory is an error, not an empty result" do
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { check(inventory: "") }
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { check(inventory: "H #{DIGEST} #{MARKER}\n") }
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { check(inventory: "H #{DIGEST} #{MARKER}\nNOSTATE\n") }
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { check(inventory: "H - #{MARKER}\nEND\n") }
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { check(inventory: "END\n") }
  end

  test "digests and paths are validated before docker is touched" do
    calls = []
    [ { MARKER => nil }, { MARKER => "" }, { MARKER => "abc" }, { "decoy/x" => DIGEST },
      { "claude/projects/../x" => DIGEST }, { "claude/projects/project notes/session.jsonl" => DIGEST },
      { "claude/projects/*/session.jsonl" => DIGEST }, { "claude/projects/x//y" => DIGEST } ].each do |expect|
      assert_raises(ArgumentError, expect.inspect) do
        Backup::TranscriptRestoreCheck.new(@agent, expect:, run: runner(calls))
      end
    end
    assert_empty calls
  end

  test "the inventory hashes the literal path, never a file reached by splitting or globbing it" do
    put("claude/projects/project/notes/session.jsonl")
    put("claude/projects/other/session.jsonl")
    lines = inventory("claude/projects/project notes/session.jsonl", "claude/projects/*/session.jsonl")
    assert_includes lines, "H absent claude/projects/project notes/session.jsonl"
    assert_includes lines, "H absent claude/projects/*/session.jsonl"
    assert_not(lines.any? { it.start_with?("H #{DIGEST}") }, "no digest is credited to a path that is not there")

    put("claude/projects/project notes/session.jsonl")
    assert_includes inventory("claude/projects/project notes/session.jsonl"),
      "H #{DIGEST} claude/projects/project notes/session.jsonl"
  end

  test "a refused empty directory is seen, in the restore listing and in the baseline" do
    put(MARKER)
    FileUtils.mkdir_p(File.join(@root, "decoy-dir"))
    report, = check(refuse: [ "decoy-dir" ])
    assert_equal({ "decoy-dir" => true }, report.refused)
    assert_equal "failed", report.verdict

    calls = []
    run = ->(argv) { calls << argv; argv.include?("ls") ? [ ls([ MARKER, "file", 1 ], [ "decoy-dir", "dir", 0 ]), true ] : [ "", true ] }
    report = Backup::TranscriptRestoreCheck.new(@agent, refuse: [ "decoy-dir" ], run:).call
    assert_equal({ "decoy-dir" => true }, report.refused)
    assert_equal "failed", report.verdict
  end

  test "a linked state root, or a linked parent of it, is refused before anything is listed or hashed" do
    real = @root
    put(MARKER)
    links = Dir.mktmpdir("links")
    File.symlink(real, File.join(links, "state"))
    FileUtils.mkdir_p(File.join(links, "parent-real/state"))
    FileUtils.cp_r(File.join(real, "claude"), File.join(links, "parent-real/state"))
    File.symlink(File.join(links, "parent-real"), File.join(links, "parent-link"))

    [ File.join(links, "state"), File.join(links, "parent-link/state") ].each do |linked|
      @root = linked
      assert_equal [ "LINKEDROOT", "END" ], inventory(MARKER), linked
      error = assert_raises(Backup::TranscriptRestoreCheck::Failed) { check }
      assert_match(/state root or one of its parents is a link/, error.message)
    end
  ensure
    @root = real
    FileUtils.remove_entry(links) if links
  end

  test "a tool container still there after removal is named and never green; an absent one is fine" do
    put(MARKER)
    report, calls = check
    assert report.ok?
    assert_equal 2, calls.count { it[1] == "ps" }

    report, = check(ps_out: "deadbeef\n")
    assert_equal "recovered", report.verdict
    assert_not report.ok?
    assert_equal 2, report.cleanup[:containers].size
    assert_match(/containers not removed: transcript-restore-check-\h{16}/, report.cleanup[:error])
  end

  test "a failed volume removal is visible and never green" do
    put(MARKER)
    report, = check(rm_ok: false)
    assert_equal "recovered", report.verdict
    assert_not report.ok?
    assert_equal false, report.cleanup[:ok]
    assert_match(/\Atranscript-restore-check-\h{12}\z/, report.cleanup[:volume])
  end

  test "a failed restore raises, removes the volume, and names it when that fails too" do
    calls = []
    error = assert_raises(Backup::TranscriptRestoreCheck::Failed) do
      Backup::TranscriptRestoreCheck.new(@agent, expect: { MARKER => DIGEST }, run: runner(calls, restore_ok: false)).call
    end
    assert_equal "docker restore failed", error.message
    assert(calls.any? { it[1, 2] == %w[volume rm] })

    error = assert_raises(Backup::TranscriptRestoreCheck::Failed) { check(restore_ok: false, rm_ok: false) }
    assert_match(/docker restore failed \(and the throwaway volume transcript-restore-check-\h{12} was not removed\)/, error.message)
  end

  def ls(*nodes, snapshot: true)
    lines = []
    lines << { struct_type: "snapshot", id: "a" * 64 }.to_json if snapshot
    nodes.each { |path, type, size| lines << { struct_type: "node", path: "/data/state/#{path}", type:, size: }.to_json }
    lines.join("\n") + "\n"
  end

  def baseline(output)
    calls = []
    run = ->(argv) { calls << argv; argv.include?("ls") ? [ output, true ] : [ "", true ] }
    [ Backup::TranscriptRestoreCheck.new(@agent, run:).call, calls ]
  end

  test "the baseline is metadata only: counts and bytes from restic ls, nothing restored, no path printed" do
    report, calls = baseline(ls([ "claude", "dir", 0 ], [ "claude/projects/-p/s1.jsonl", "file", 100 ],
      [ "claude/projects/-p/s2.jsonl", "file", 50 ]))

    assert report.ok?
    assert_equal "present", report.verdict
    assert_equal({ files: 2, bytes: 150 }, report.by_path["claude/projects"])
    assert_not(calls.any? { it.include?("restore") || it[1] == "volume" })
    assert_equal [ "ls", "--json", "--recursive", "a" * 64, "/data/state" ], calls.first.last(5)
    assert_not_includes report.to_h.to_json, "s1.jsonl"
  end

  test "a baseline with no transcript files says so and is not a pass" do
    report, = baseline(ls)
    assert_equal "no_transcript_data", report.verdict
    assert_not report.ok?
  end

  test "a baseline with anything outside the transcript paths fails, counting it without naming it" do
    report, = baseline(ls([ "claude/projects/-p/s1.jsonl", "file", 100 ], [ "claude/.credentials.json", "file", 40 ]))
    assert_equal "failed", report.verdict
    assert_equal 1, report.outside_count
    assert_not_includes report.to_h.to_json, "credentials"
  end

  test "a baseline listing that does not describe the snapshot is an error" do
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { baseline(ls([ "claude/projects/x", "file", 1 ], snapshot: false)) }
    assert_raises(Backup::TranscriptRestoreCheck::Failed) { baseline("not json\n") }
  end

  test "a resident with no verified backup is refused before docker is touched" do
    @snapshot.update!(ok: false)
    calls = []
    assert_raises(Backup::TranscriptRestoreCheck::Failed) do
      Backup::TranscriptRestoreCheck.new(@agent, run: runner(calls)).call
    end
    assert_empty calls
  end

end
