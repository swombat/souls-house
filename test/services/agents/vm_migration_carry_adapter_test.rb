require "test_helper"
require "aws-sdk-s3"
require "net/http"

# The carry writer's loopback adapter (#426 slice 3C, checkpoint 2). Synthetic
# S3 only. Not transactional: Rails' transactional tests make every thread
# share the test's connection, which would hide the property this file is
# about (each adapter write in its own short transaction, on its own
# connection, while the stage holds the resident's row lock on another).
class Agents::VmMigrationCarryAdapterTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  UUID = "33333333-3333-4333-8333-333333333333"
  A = "a" * 64
  B = "b" * 64
  Resident = Struct.new(:id, :uuid)

  setup do
    @resident = Resident.new(agents(:research_assistant).id, UUID)
    @prefix = "agents/#{UUID}/"
    @objects = {}
    @mutex = Mutex.new
    @client = Aws::S3::Client.new(region: "us-east-1", stub_responses: true)
    @client.stub_responses(:head_object, lambda do |context|
      body = @mutex.synchronize { @objects[context.params[:key]] }
      body ? { content_length: body.bytesize } : "NotFound"
    end)
    @client.stub_responses(:get_object, lambda do |context|
      body = @mutex.synchronize { @objects[context.params[:key]] }
      body ? { body:, content_length: body.bytesize } : "NoSuchKey"
    end)
    @on_put = nil
    @client.stub_responses(:put_object, lambda do |context|
      @on_put&.call
      @mutex.synchronize do
        next "PreconditionFailed" if @objects.key?(context.params[:key])

        @objects[context.params[:key]] = context.params[:body].then { |body| body.respond_to?(:read) ? body.read : body }
        {}
      end
    end)
    @client.stub_responses(:list_objects_v2, lambda do |context|
      contents = @mutex.synchronize { @objects.filter_map { |key, body| { key:, size: body.bytesize } if key.start_with?(context.params[:prefix]) } }
      { contents:, is_truncated: false }
    end)
    @budget = 20.gigabytes
  end

  def open_adapter(deadline: Agents::BoundedCommand.now + 60, read_only: false, &block)
    factory = ->(resident) { Backup::VmRepository.new(agent: resident, client: @client, bucket: "synthetic-backups", budget_bytes: @budget) }
    Agents::VmMigration::CarryAdapter.open(@resident, deadline:, repository_factory: factory, read_only:, &block)
  end

  def credential(adapter)
    URI(adapter.repository_url.delete_prefix("rest:")).then { |uri| [ uri.user, uri.password ] }
  end

  def call(adapter, method, path, body: nil, auth: credential(adapter), headers: {})
    Net::HTTP.start("127.0.0.1", adapter.port, read_timeout: 10) do |http|
      request = Net::HTTPGenericRequest.new(method, !body.nil?, method != "HEAD", path, headers)
      request.basic_auth(*auth) if auth
      request.body = body if body
      http.request(request)
    end
  end

  def raw(adapter, text)
    socket = TCPSocket.new("127.0.0.1", adapter.port)
    socket.write(text)
    socket.close_write
    socket.read
  rescue Errno::ECONNRESET, Errno::EPIPE
    "" # refused and closed before the client read the answer
  ensure
    socket&.close
  end

  def observer = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)

  def try_lock(connection, key) = connection.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0) == "t"

  def repository_key = Backup::VmRepository.lock_key("repository:synthetic-backups:#{@prefix}")

  test "each write holds the repository lock only for its own commit while the stage holds the resident row lock" do
    held_during_commit = []
    @on_put = lambda do
      connection = observer
      held_during_commit << !try_lock(connection, repository_key)
    ensure
      connection.exec("SELECT pg_advisory_unlock_all()")
      connection.close
    end
    open_adapter do |adapter|
      agent = Agent.find(@resident.id)
      Agent.transaction do
        agent.lock! # the stage's row lock, on the test thread's own connection
        assert_equal "200", call(adapter, "POST", "/data/#{A}", body: "one").code
        between = observer
        begin
          assert try_lock(between, repository_key), "another session takes the repository lock between two adapter writes"
        ensure
          between.exec("SELECT pg_advisory_unlock_all()")
          between.close
        end
        assert_equal "200", call(adapter, "POST", "/data/#{B}", body: "two").code
      end
    end
    assert_equal [ true, true ], held_during_commit, "the lock is held across each S3 commit"
    assert_equal "one", @objects["#{@prefix}data/aa/#{A}"]
    assert_equal "two", @objects["#{@prefix}data/bb/#{B}"]
  end

  test "another writer holding the repository lock makes a write busy, not corrupt" do
    connection = observer
    begin
      assert try_lock(connection, repository_key)
      open_adapter do |adapter|
        response = call(adapter, "POST", "/data/#{A}", body: "one")
        assert_equal "503", response.code
        assert_equal "backup_storage_busy", response.body
      end
    ensure
      connection.exec("SELECT pg_advisory_unlock_all()")
      connection.close
    end
    assert_empty @objects
  end

  test "the budget refuses a write partway through a snapshot and an identical retry still passes" do
    @budget = 5
    open_adapter do |adapter|
      assert_equal "200", call(adapter, "POST", "/data/#{A}", body: "four").code
      refused = call(adapter, "POST", "/data/#{B}", body: "more")
      assert_equal "507", refused.code
      assert_equal "backup_budget_exceeded", refused.body
      assert_equal "200", call(adapter, "POST", "/data/#{A}", body: "four").code, "identical retry passes with the budget full"
      assert_equal "409", call(adapter, "POST", "/data/#{A}", body: "FOUR").code, "never overwrites"
    end
    assert_equal [ "#{@prefix}data/aa/#{A}" ], @objects.keys
  end

  test "a read-only adapter refuses DELETE of a lock without reaching the repository" do
    deletes = []
    factory = lambda do |resident|
      Backup::VmRepository.new(agent: resident, client: @client, bucket: "synthetic-backups", budget_bytes: @budget).tap do |repository|
        repository.define_singleton_method(:delete_lock) { |path| deletes << path }
      end
    end
    Agents::VmMigration::CarryAdapter.open(@resident, deadline: Agents::BoundedCommand.now + 60, repository_factory: factory) do |adapter|
      assert_equal "200", call(adapter, "DELETE", "/locks/#{A}").code
    end
    assert_equal 1, deletes.size, "the writable adapter reaches delete_lock"
    Agents::VmMigration::CarryAdapter.open(@resident, deadline: Agents::BoundedCommand.now + 60, repository_factory: factory,
      read_only: true) do |adapter|
      assert_equal "403", call(adapter, "DELETE", "/locks/#{B}").code
    end
    assert_equal 1, deletes.size, "the read-only adapter never calls delete_lock"
  end

  test "only this run's credential is accepted" do
    open_adapter do |adapter|
      user, password = credential(adapter)
      assert_equal "401", call(adapter, "GET", "/config", auth: nil).code
      assert_equal "401", call(adapter, "GET", "/config", auth: [ user, "#{password}x" ]).code
      assert_equal "401", call(adapter, "POST", "/config", body: "x", auth: [ "other", password ]).code
      assert_equal "404", call(adapter, "GET", "/config").code
    end
    assert_empty @objects
  end

  test "the repository is the captured resident's whatever the request says" do
    open_adapter do |adapter|
      assert_equal "400", call(adapter, "POST", "/agents/#{UUID}/config", body: "x").code
      assert_equal "400", call(adapter, "POST", "/data/aa/#{A}", body: "x").code
      assert_equal "400", call(adapter, "GET", "/../config").code
      assert_equal "200", call(adapter, "POST", "/config", body: "cfg").code
    end
    assert_equal [ "#{@prefix}config" ], @objects.keys
  end

  test "restic's listing, head and range reads are served as the backup endpoint serves them" do
    @objects["#{@prefix}data/aa/#{A}"] = "hello world"
    open_adapter do |adapter|
      listing = call(adapter, "GET", "/data/", headers: { "Accept" => Backup::VmRepository::V2_MEDIA_TYPE })
      assert_equal Backup::VmRepository::V2_MEDIA_TYPE, listing["Content-Type"]
      assert_equal [ { "name" => A, "size" => 11 } ], JSON.parse(listing.body)
      assert_equal "11", call(adapter, "HEAD", "/data/#{A}")["Content-Length"]
      ranged = call(adapter, "GET", "/data/#{A}", headers: { "Range" => "bytes=0-4" })
      assert_equal "200", call(adapter, "GET", "/data/#{A}").code
      assert_includes %w[200 206], ranged.code
    end
  end

  test "requests are bounded before anything is read into a repository" do
    open_adapter do |adapter|
      user, password = credential(adapter)
      auth = "Authorization: Basic #{Base64.strict_encode64("#{user}:#{password}")}\r\n"
      assert_match %r{\AHTTP/1.1 400}, raw(adapter, "POST /data/#{A} HTTP/1.1\r\n#{auth}Transfer-Encoding: chunked\r\n\r\n")
      assert_match %r{\AHTTP/1.1 400}, raw(adapter, "POST /data/#{A} HTTP/1.1\r\n#{auth}Content-Length: #{Backup::VmRepository::MAX_BYTES + 1}\r\n\r\n")
      assert_match %r{\AHTTP/1.1 400}, raw(adapter, "GET /config HTTP/1.1\r\nX: #{'y' * 9.kilobytes}\r\n\r\n")
      assert_match %r{\AHTTP/1.1 400}, raw(adapter, "GET /config HTTP/1.1\r\n#{(1..40).map { |n| "X#{n}: y\r\n" }.join}\r\n")
      assert_match %r{\AHTTP/1.1 400}, raw(adapter, "GET /config HTTP/1.1\r\n#{auth}#{auth}\r\n")
      # Physical lines count, not distinct names (Kevin's 5,000 "X: y" lines).
      assert_match %r{\AHTTP/1.1 400}, raw(adapter, "GET /config HTTP/1.1\r\n#{"X: y\r\n" * 40}\r\n")
    end
    assert_empty @objects
  end

  test "a past deadline refuses every repository request" do
    open_adapter(deadline: Agents::BoundedCommand.now - 1) do |adapter|
      assert_equal "", raw(adapter, "GET /config HTTP/1.1\r\n\r\n").then { |text| text.start_with?("HTTP/1.1 503") ? "" : text }
    end
  end

  test "the probe answers only this run's token and needs no credential" do
    open_adapter do |adapter|
      path = URI(adapter.probe_url).path
      response = call(adapter, "GET", path, auth: nil)
      assert_equal "200", response.code
      assert_equal adapter.probe_answer, response.body
      assert_equal "404", call(adapter, "GET", "/.carry-probe/#{'0' * 32}", auth: nil).code
    end
  end

  test "an unexpected failure answers without the credential or its message" do
    secret = nil
    factory = ->(_resident) { raise ArgumentError, "boom #{secret}" }
    Agents::VmMigration::CarryAdapter.open(@resident, deadline: Agents::BoundedCommand.now + 60, repository_factory: factory) do |adapter|
      secret = credential(adapter).last
      response = call(adapter, "GET", "/config")
      assert_equal "500", response.code
      refute_includes response.body, secret
      refute_includes response.to_hash.to_s, secret
      assert_equal [ "ArgumentError" ], adapter.failures
    end
  end

  def adapter_threads(adapter)
    adapter.instance_variable_get(:@handlers).select(&:alive?)
  end

  def trickle(adapter, count)
    Array.new(count) { TCPSocket.new("127.0.0.1", adapter.port) }.tap do |sockets|
      sockets.each { |socket| socket.write("G") }
    end
  end

  test "busy connections are refused without a thread each, and stop closes connections still sending" do
    baseline = Thread.list.count(&:alive?)
    open_adapter do |adapter|
      held = trickle(adapter, Agents::VmMigration::CarryAdapter::MAX_CONNECTIONS)
      wait_until { adapter_threads(adapter).size == Agents::VmMigration::CarryAdapter::MAX_CONNECTIONS }
      extra = trickle(adapter, 12)
      sleep 0.3
      extra.each { |socket| socket.write("E") rescue nil }
      sleep 0.2
      # Two handlers and the acceptor, never one thread per refused client.
      assert_operator Thread.list.count(&:alive?), :<=, baseline + 3
      held.each { |socket| socket.write("E") }
      started = Agents::BoundedCommand.now
      adapter.stop
      assert_operator Agents::BoundedCommand.now - started, :<, 2, "stop waits for no client that is still sending"
      assert_empty adapter_threads(adapter)
      (held + extra).each { |socket| socket.close rescue nil }
    end
    assert_operator Thread.list.count(&:alive?), :<=, baseline
  end

  test "a client that stops reading a large answer can't hold the writer past the deadline" do
    key = "#{@prefix}data/aa/#{A}"
    @objects[key] = "z".b * 32.megabytes
    open_adapter(deadline: Agents::BoundedCommand.now + 2) do |adapter|
      user, password = credential(adapter)
      socket = TCPSocket.new("127.0.0.1", adapter.port)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
      socket.write("GET /data/#{A} HTTP/1.1\r\nAuthorization: Basic #{Base64.strict_encode64("#{user}:#{password}")}\r\n\r\n")
      assert_equal "HTTP/1.1 200", socket.read(12), "the large answer is being written"
      wait_until(timeout: 10) { adapter_threads(adapter).empty? }
      assert_empty adapter_threads(adapter), "the writer gave up at the deadline"
      socket.close
    end
  end

  def wait_until(timeout: 5)
    ends = Agents::BoundedCommand.now + timeout
    sleep 0.05 until yield || Agents::BoundedCommand.now > ends
  end

  test "stop closes the port" do
    port = open_adapter(&:port)
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new("127.0.0.1", port) }
  end

  test "a read-only adapter (a rollback restore) serves reads and refuses every write, lock included" do
    open_adapter { |adapter| assert_equal "200", call(adapter, "POST", "/data/#{A}", body: "one").code }
    open_adapter(read_only: true) do |adapter|
      assert_equal "200", call(adapter, "GET", "/data/#{A}").code
      assert_equal "403", call(adapter, "POST", "/data/#{B}", body: "two").code
      assert_equal "403", call(adapter, "POST", "/locks/#{B}", body: "lock").code
      assert_equal "403", call(adapter, "POST", "/?create=true").code
    end
    assert_equal [ "#{@prefix}data/aa/#{A}" ], @objects.keys
  end

end
