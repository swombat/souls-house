require "minitest/autorun"
require "pg"
require "json"
require "securerandom"
require "open3"
require "timeout"

# The real adapter and PostgreSQL in separate OS processes. Nothing loads the
# application environment or accesses a numbered instance/application database.
class SolidCableUpgradeTest < Minitest::Test

  ROOT = File.expand_path("../..", __dir__)

  def setup
    @schema = "cable_probe_#{SecureRandom.hex(12)}"
    @children = []
    host = ENV.fetch("PGHOST")
    raise "Cable probe requires local test PostgreSQL" unless host.start_with?("/") || %w[localhost 127.0.0.1 postgres].include?(host)
    @db = PG.connect(host: host, port: ENV["PGPORT"], user: ENV["PGUSER"] || ENV.fetch("USER"),
      password: ENV["PGPASSWORD"], dbname: "postgres")
    @db.exec("CREATE SCHEMA #{@db.quote_ident(@schema)}")
    @db.exec("SET search_path TO #{@db.quote_ident(@schema)}")
    seed = child("schema")
    assert_equal "schema", event(seed).fetch("event")
    finish(seed)
  end

  def teardown
    @children&.each do |process|
      input, output, error, wait = process
      input.close unless input.closed?
      unless wait.join(3)
        Process.kill("TERM", wait.pid)
        wait.join(3) || Process.kill("KILL", wait.pid)
        wait.join
      end
      output.close
      error.close
    end
    # Only the random schema created by this run; never a shared app schema/DB.
    @db&.exec("DROP SCHEMA IF EXISTS #{@db.quote_ident(@schema)} CASCADE") if @schema&.match?(/\Acable_probe_[0-9a-f]{24}\z/)
    @db&.close
  end

  def test_first_delivery_reconnect_shutdown_flush_and_retention
    subscriber = child("subscriber")
    assert_equal "ready", event(subscriber).fetch("event")
    publisher = child("publisher")
    broadcast(publisher, "first-after-subscribe")
    assert_equal({ "event" => "message", "payload" => "first-after-subscribe" }, event(subscriber))

    # Terminate only this run's subscriber sessions, not the database/server or
    # any application connection. The real listener must reconnect and deliver.
    terminated = @db.exec_params(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = $1",
      [ "#{@schema}_subscriber" ])
    assert_operator terminated.ntuples, :>, 0
    assert terminated.all? { |row| row.fetch("pg_terminate_backend") == "t" }
    broadcast(publisher, "database-reconnected")
    assert_equal({ "event" => "message", "payload" => "database-reconnected" }, event(subscriber))

    command(subscriber, "unsubscribe")
    assert_equal "unsubscribed", event(subscriber).fetch("event")
    broadcast(publisher, "while-unsubscribed")
    command(publisher, "shutdown")
    assert_equal "flushed", event(publisher).fetch("event")
    finish(publisher)
    command(subscriber, "reconnect")
    assert_equal "ready", event(subscriber).fetch("event")
    publisher = child("publisher")
    broadcast(publisher, "after-reconnect")
    assert_equal({ "event" => "message", "payload" => "after-reconnect" }, event(subscriber))
    command(publisher, "shutdown")
    assert_equal "flushed", event(publisher).fetch("event")
    finish(publisher)

    # Hold a batch for five seconds; closing the writer must flush immediately,
    # without waiting for the normal batch deadline or dropping its tail.
    publisher = child("publisher", "delayed")
    %w[tail-1 tail-2 tail-3].each { |payload| broadcast(publisher, payload) }
    command(publisher, "shutdown")
    assert_equal "flushed", event(publisher).fetch("event")
    finish(publisher)
    assert_equal %w[tail-1 tail-2 tail-3], 3.times.map { event(subscriber).fetch("payload") }
    assert_equal 8, @db.exec("SELECT count(*) FROM solid_cable_messages").getvalue(0, 0).to_i

    trim = child("trim")
    assert_equal({ "event" => "trim", "before" => 8, "after" => 7 }, event(trim))
    finish(trim)
    assert_equal 0, @db.exec_params("SELECT count(*) FROM solid_cable_messages WHERE payload = $1::bytea", [ "expired" ]).getvalue(0, 0).to_i
    command(subscriber, "shutdown")
    assert_equal "flushed", event(subscriber).fetch("event")
    finish(subscriber)
  end

  private

  def child(*arguments)
    environment = ENV.to_h.slice("PATH", "HOME", "USER", "LANG", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH",
      "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD")
      .merge("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "CABLE_PROBE_SCHEMA" => @schema)
    process = Open3.popen3(environment, "bundle", "exec", "ruby", File.join(ROOT, "test/support/solid_cable_probe.rb"),
      *arguments, chdir: ROOT, unsetenv_others: true)
    @children << process
    process
  end

  def command(process, command, **options)
    process[0].puts(JSON.generate(command: command, **options))
    process[0].flush
  end

  def broadcast(process, payload)
    command(process, "broadcast", payload: payload)
    assert_equal "accepted", event(process).fetch("event")
  end

  def event(process)
    Timeout.timeout(15) do
      loop do
        line = process[1].gets
        raise "Probe exited: #{process[2].read}" unless line
        next unless line.start_with?("{")
        result = JSON.parse(line)
        flunk "Adapter reported #{result}" if result["event"] == "error"
        return result
      end
    end
  end

  def finish(process)
    assert process[3].join(10), "Probe did not exit"
    assert process[3].value.success?, process[2].read
  end

end
