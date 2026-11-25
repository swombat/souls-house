require "test_helper"

# A fake `docker` on PATH stands in for the accessory; FAKE_DOCKER says how it behaves.
class Backup::CommsTelegramDumpJobTest < ActiveJob::TestCase

  setup do
    @bin = Dir.mktmpdir("fake-docker")
    File.write(File.join(@bin, "docker"), <<~'SH')
      #!/bin/sh
      if [ "$1" = inspect ]; then
        case "$FAKE_DOCKER" in stopped) echo false ;; missing) echo "No such object" >&2; exit 1 ;;
          hang_inspect) sleep 60 ;; *) echo true ;; esac
        exit 0
      fi
      [ -n "$FAKE_DOCKER_ARGS" ] && echo "$@" > "$FAKE_DOCKER_ARGS"
      case "$FAKE_DOCKER" in
        hang) sleep 60 ;;
        noisy) i=0; while [ $i -lt 20000 ]; do echo 'a diagnostic line that is fifty bytes or so long..' >&2; i=$((i+1)); done
               printf 'TGBACKUP\001'
               echo '{"chunks": 1, "connections": 2, "done": "dump", "tables": {"outbox": 3}}' >&2 ;;
        ok) printf 'TGBACKUP\001\000\000\000\002{}\377\376binary\000tail'
            echo '{"chunks": 1, "connections": 2, "done": "dump", "tables": {"outbox": 3}}' >&2 ;;
        old) echo '/usr/local/bin/python: No module named connector.backup' >&2; exit 1 ;;
        refused) echo 'postgresql://u:hunter2@db/x' >&2; echo '{"refused": "schema_version"}' >&2; exit 2 ;;
        crash) echo 'Traceback: postgresql://u:hunter2@db/x' >&2; exit 1 ;;
        silent) printf 'TGBACKUP' ;;
        garbage) printf 'NOTADUMP'; echo '{"done": "dump"}' >&2 ;;
      esac
    SH
    File.chmod(0o755, File.join(@bin, "docker"))
    @path = ENV["PATH"]
    ENV["PATH"] = "#{@bin}:#{@path}"
    @url = ENV["COMMS_CONNECTOR_URL"]
    ENV["COMMS_CONNECTOR_URL"] = "https://souls-house-comms-telegram:8443"
    @uploads = []
  end

  teardown do
    ENV["PATH"] = @path
    ENV["COMMS_CONNECTOR_URL"] = @url
    ENV.delete("FAKE_DOCKER")
    FileUtils.rm_rf(@bin)
  end

  def run_job(mode, inspect_timeout: 30, dump_timeout: 60)
    ENV["FAKE_DOCKER"] = mode
    job = Backup::CommsTelegramDumpJob.new
    job.stub(:inspect_timeout, inspect_timeout) do
      job.stub(:dump_timeout, dump_timeout) do
        job.stub(:upload!, ->(path, key) { @uploads << [ key, File.binread(path) ] }) do
          job.stub(:prune!, ->(key) { @pruned = key }) { job.perform_now }
        end
      end
    end
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def prune_with(ages_in_days, uploaded:)
    client = Aws::S3::Client.new(stub_responses: true)
    contents = ages_in_days.map.with_index do |days, i|
      { key: "comms-telegram/#{i}.tgbackup", last_modified: days.days.ago }
    end
    contents << { key: uploaded, last_modified: Time.current } if uploaded
    client.stub_responses(:list_objects_v2, { contents: contents, is_truncated: false })
    job = Backup::CommsTelegramDumpJob.new
    job.stub(:s3_client, client) do
      job.stub(:bucket_name, "bucket") { job.send(:prune!, "comms-telegram/new.tgbackup") }
    end
    client.api_requests.select { |r| r[:operation_name] == :delete_object }.map { |r| r[:params][:key] }
  end

  test "prunes dumps older than 14 days, keeping the newest three" do
    assert_equal %w[comms-telegram/2.tgbackup comms-telegram/3.tgbackup],
                 prune_with([ 1, 2, 20, 30 ], uploaded: "comms-telegram/new.tgbackup").sort
    # Only old ones left besides the new dump: the newest three survive regardless.
    assert_equal %w[comms-telegram/2.tgbackup comms-telegram/3.tgbackup],
                 prune_with([ 15, 16, 17, 18 ], uploaded: "comms-telegram/new.tgbackup").sort
  end

  test "fewer than three dumps are all kept, however old: 14 days is a target, not a maximum" do
    assert_empty prune_with([ 40 ], uploaded: "comms-telegram/new.tgbackup")
    assert_empty prune_with([ 40, 90 ], uploaded: "comms-telegram/new.tgbackup")
  end

  test "a hung docker inspect is a named failure within its deadline" do
    error = nil
    elapsed = timed { error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("hang_inspect", inspect_timeout: 1) } }
    assert_equal "inspect_timeout", error.message
    assert_operator elapsed, :<, 10
  end

  test "a hung dump is killed with its process group and named" do
    error = nil
    elapsed = timed { error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("hang", dump_timeout: 1) } }
    assert_equal "dump_timeout", error.message
    assert_operator elapsed, :<, 10
    assert_empty @uploads
  end

  test "the dump inside the container carries its own shorter deadline" do
    args = File.join(@bin, "args")
    ENV["FAKE_DOCKER_ARGS"] = args
    run_job("ok")
    argv = File.read(args).split
    assert_equal %w[exec souls-house-comms-telegram python -m connector.backup dump --deadline], argv[0, 7]
    assert_operator argv[7].to_i, :<, Backup::CommsTelegramDumpJob::TIMEOUT.to_i
  ensure
    ENV.delete("FAKE_DOCKER_ARGS")
  end

  test "a megabyte of diagnostics keeps the closing summary and stays bounded" do
    run_job("noisy")
    assert_equal 1, @uploads.size
  end

  test "never prunes unless the new dump is in the bucket" do
    assert_raises(Backup::CommsTelegramDumpJob::Failed) { prune_with([ 20, 30 ], uploaded: nil) }
  end

  test "uploads the sealed bytes exactly as the connector wrote them" do
    run_job("ok")
    assert_equal 1, @uploads.size
    key, bytes = @uploads.first
    assert_match %r{\Acomms-telegram/\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.tgbackup\z}, key
    assert_equal "TGBACKUP\x01\x00\x00\x00\x02{}\xFF\xFEbinary\x00tail".b, bytes
  end

  test "the nightly run deletes nothing until retention is agreed" do
    refute Backup::CommsTelegramDumpJob::PRUNE
    run_job("ok")
    assert_equal 1, @uploads.size
    assert_nil @pruned
  end

  test "skips only when the connector is not configured" do
    ENV.delete("COMMS_CONNECTOR_URL")
    run_job("ok")
    assert_empty @uploads
  end

  test "a configured connector that is not running is a failure" do
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("stopped") }
    assert_equal "connector_not_running", error.message
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("missing") }
    assert_equal "connector_not_running", error.message
  end

  test "an image without the backup command is a named failure, not a success" do
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("old") }
    assert_equal "connector_image_lacks_backup", error.message
    assert_empty @uploads
  end

  test "failures carry the connector's token, never its stderr" do
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("refused") }
    assert_equal "dump_schema_version", error.message
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("crash") }
    assert_equal "dump_exit_1", error.message
    refute_includes error.message, "hunter2"
    assert_empty @uploads
  end

  test "an unconfirmed or malformed dump is not uploaded" do
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("silent") }
    assert_equal "dump_unconfirmed", error.message
    error = assert_raises(Backup::CommsTelegramDumpJob::Failed) { run_job("garbage") }
    assert_equal "dump_malformed", error.message
    assert_empty @uploads
  end

end
