require "test_helper"
require "rubygems/package"

class Backup::VmRestoreCheckTest < ActiveSupport::TestCase

  def tar(files, prefix: "")
    io = StringIO.new("".b)
    Gem::Package::TarWriter.new(io) do |writer|
      files.each { |path, content| writer.add_file_simple("#{prefix}#{path}", 0o644, content.bytesize) { |f| f.write(content) } }
    end
    io.string
  end

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(uuid: SecureRandom.uuid_v7, restic_password: "pw")
    @seed = { "soul.md" => "# soul\n", "memory/daily-journals/README.md" => "readme\n" }
    @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242,
      seed_archive: Zlib.gzip(tar(@seed)), seed_sha256: "x")
    @snapshot = AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "a" * 64, taken_at: Time.current, ok: true)
  end

  def check(restored)
    calls = []
    capture = lambda do |*args|
      calls << args
      args.first == "dump" && args.last == "/data/identity" ? tar(restored, prefix: "/data/identity/") : ""
    end
    [ Backup::VmRestoreCheck.new(@agent, capture:).call, calls ]
  end

  test "every seed file restored byte for byte, with additions listed but not failed" do
    report, calls = check(@seed.merge(".souls-house-seed" => "digest\n", "memory/daily-journals/2026-10-10.md" => "hello\n"))
    assert_equal [ "dump", "a" * 64, "/data/identity" ], calls.first
    assert_equal 2, report.matched
    assert_empty report.missing
    assert_empty report.different
    assert_equal [ ".souls-house-seed", "memory/daily-journals/2026-10-10.md" ], report.added
  end

  test "a missing or changed seed file fails the check" do
    report, = check("soul.md" => "# someone else\n")
    assert_equal [ "memory/daily-journals/README.md" ], report.missing
    assert_equal [ "soul.md" ], report.different
    assert_not report.ok?
  end

  test "without slice 4's records the checkpoint cannot be confirmed, so the check is not ok" do
    report, = check(@seed)
    unless defined?(VmBackup)
      assert_not report.checkpoint_ok
      assert_not report.ok?
    end
  end

  test "refuses a resident that is not on a VM, has no seed, or has no verified backup" do
    @snapshot.update!(ok: false)
    assert_raises(Backup::VmRestoreCheck::Failed) { check(@seed) }
    @placement.update!(seed_archive: nil)
    assert_raises(Backup::VmRestoreCheck::Failed) { check(@seed) }
    @placement.update!(backend: "local", state: "ready", provider_server_id: nil)
    assert_raises(Backup::VmRestoreCheck::Failed) { check(@seed) }
  end


  test "a stalled child is killed at the timeout, its group reaped, and the container cleanup still runs" do
    cleaned = []
    pid_file = Rails.root.join("tmp", "stalled-#{SecureRandom.hex(4)}.pid")
    builder = ->(_name, _args) { [ "sh", "-c", "echo $$ > #{pid_file}; sleep 30" ] }
    check = Backup::VmRestoreCheck.new(@agent, argv_builder: builder, cleanup: ->(name) { cleaned << name }, timeout: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Backup::VmRestoreCheck::Failed) { check.call }
    assert_match(/timed out/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    assert_equal 1, cleaned.size
    assert_match(/\Avm-restore-check-\h{16}\z/, cleaned.first)
    child = File.read(pid_file).to_i
    assert_raises(Errno::ESRCH) { Process.kill(0, child) }
  ensure
    File.delete(pid_file) if pid_file && File.exist?(pid_file)
  end

  test "a failing child reports a bounded tail of its stderr" do
    builder = ->(_name, _args) { [ "sh", "-c", "head -c 100000 /dev/zero | tr '\\\\0' x >&2; echo the-real-reason >&2; exit 3" ] }
    check = Backup::VmRestoreCheck.new(@agent, argv_builder: builder, cleanup: ->(_) {}, timeout: 10)
    error = assert_raises(Backup::VmRestoreCheck::Failed) { check.call }
    assert_match(/the-real-reason/, error.message)
    assert_operator error.message.bytesize, :<, 700
  end

end
