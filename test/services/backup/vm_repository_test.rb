require "test_helper"
require "timeout"
require "aws-sdk-s3"

class Backup::VmRepositoryTest < ActiveSupport::TestCase

  ID = "a" * 64
  OTHER_ID = "b" * 64

  setup do
    @agent = agents(:research_assistant)
    @prefix = "agents/#{@agent.uuid}/"
    @objects = {}
    @puts = []
    @deletes = []
    # Explicit exception to the no-mocks guidance: this slice is required to
    # use synthetic S3 only, with no resident credentials or external service.
    @client = Aws::S3::Client.new(region: "us-east-1", stub_responses: true)
    @client.stub_responses(:head_object, lambda do |context|
      body = @objects[context.params[:key]]
      body ? { content_length: body.bytesize } : "NotFound"
    end)
    @client.stub_responses(:get_object, lambda do |context|
      body = @objects[context.params[:key]]
      body ? { body:, content_length: body.bytesize } : "NoSuchKey"
    end)
    @client.stub_responses(:put_object, lambda do |context|
      params = context.params
      @puts << params
      if @objects.key?(params[:key])
        "PreconditionFailed"
      else
        @objects[params[:key]] = params[:body]
        {}
      end
    end)
    @client.stub_responses(:delete_object, lambda do |context|
      @deletes << context.params[:key]
      @objects.delete(context.params[:key])
      {}
    end)
    @client.stub_responses(:list_objects_v2, lambda do |context|
      contents = @objects.filter_map do |key, body|
        { key:, size: body.bytesize } if key.start_with?(context.params[:prefix])
      end
      { contents:, is_truncated: false }
    end)
    @repository = repository
  end

  def repository(budget_bytes: 20.gigabytes)
    Backup::VmRepository.new(agent: @agent, client: @client, bucket: "synthetic-backups", budget_bytes:)
  end

  def assert_refused(code)
    error = assert_raises(Backup::VmRepository::Refused) { yield }
    assert_equal code, error.code
  end

  # Fixture pools pin all AR checkouts to one backend. A separate libpq
  # connection is essential: advisory locks are reentrant on the same session.
  def observer
    PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
  end

  def lock_value(connection, sql)
    connection.exec(sql).getvalue(0, 0) == "t"
  end

  test "only the literal restic wire grammar is accepted" do
    assert_equal :init, Backup::VmRepository.operation(method: "POST", path: "", query: "create=true")
    assert_equal :init, Backup::VmRepository.operation(method: "POST", path: "/", query: "create=true")
    %w[GET HEAD POST].each do |method|
      assert Backup::VmRepository.operation(method:, path: "config", query: "")
      assert Backup::VmRepository.operation(method:, path: "data/#{ID}", query: "")
    end
    assert_equal :delete, Backup::VmRepository.operation(method: "DELETE", path: "locks/#{ID}", query: "")
    Backup::VmRepository::TYPES.each do |type|
      assert_equal :list, Backup::VmRepository.operation(method: "GET", path: "#{type}/", query: "")
    end
    [
      [ "POST", "", "" ], [ "GET", "", "create=true" ],
      [ "POST", "", "create=true&create=true" ], [ "POST", "", "create=true&x=y" ],
      [ "POST", "", "create=%74rue" ], [ "POST", "", "create=false" ],
      [ "GET", "config", "create=true" ], [ "GET", "config", "x=y" ],
      [ "DELETE", "config", "" ], [ "DELETE", "snapshots/#{ID}", "" ],
      [ "DELETE", "keys/#{ID}", "" ], [ "DELETE", "index/#{ID}", "" ],
      [ "DELETE", "data/#{ID}", "" ], [ "PUT", "config", "" ],
      [ "HEAD", "data/", "" ], [ "POST", "keys/", "" ],
      [ "GET", "data/aa/#{ID}", "" ], [ "GET", "keys/#{'A' * 64}", "" ],
      [ "GET", "keys/#{'a' * 63}", "" ], [ "GET", "config/", "" ],
      [ "GET", "../config", "" ], [ "GET", "keys%2f#{ID}", "" ],
      [ "GET", "/config", "" ], [ "GET", "config\0", "" ]
    ].each do |method, path, query|
      assert_refused(:bad_backup_request) { Backup::VmRepository.operation(method:, path:, query:) }
    end
  end

  test "init creates nothing and never changes an existing config" do
    @objects["#{@prefix}config"] = "existing"
    assert @repository.init!
    assert_equal({ "#{@prefix}config" => "existing" }, @objects)
    assert_empty @puts
  end

  test "every object uses conditional put including config and keys" do
    [ "config", "keys/#{ID}", "locks/#{ID}", "snapshots/#{ID}", "index/#{ID}", "data/#{ID}" ].each do |path|
      assert @repository.create(path, "original")
      assert @repository.create(path, "original")
      assert_refused(:backup_overwrite_refused) { @repository.create(path, "different") }
    end
    assert_equal 18, @puts.size
    assert @puts.all? { |params| params[:if_none_match] == "*" && params[:bucket] == "synthetic-backups" }
    assert_equal "original", @objects["#{@prefix}data/aa/#{ID}"]
    refute @objects.key?("#{@prefix}data/#{ID}")
  end

  test "lists read and head use the enrollment resident prefix and wire names" do
    @objects["#{@prefix}data/aa/#{ID}"] = "pack"
    @objects["#{@prefix}data/bb/#{OTHER_ID}"] = "another"
    @objects["#{@prefix}data/cc/#{ID}"] = "malformed shard"
    @objects["agents/someone-else/data/aa/#{ID}"] = "private"
    assert_equal [ { name: ID, size: 4 }, { name: OTHER_ID, size: 7 } ], @repository.list("data")
    assert_equal 4, @repository.head("data/#{ID}")
    assert_equal "pack", @repository.read("data/#{ID}")[:body]
    refute @repository.snapshot_exists?(ID)
    @objects["#{@prefix}snapshots/#{ID}"] = "encrypted snapshot"
    assert @repository.snapshot_exists?(ID)
    refute @repository.snapshot_exists?("../config")
  end

  test "paginated listings and budgets include later pages" do
    @client.stub_responses(:list_objects_v2, [
      { contents: [ { key: "#{@prefix}snapshots/#{ID}", size: 4 } ], is_truncated: true, next_continuation_token: "next" },
      { contents: [ { key: "#{@prefix}snapshots/#{OTHER_ID}", size: 6 } ], is_truncated: false }
    ])
    assert_equal [ ID, OTHER_ID ], @repository.list("snapshots").pluck(:name)
    assert_equal "next", @client.api_requests.select { |request| request[:operation_name] == :list_objects_v2 }.last[:params][:continuation_token]
    @client.stub_responses(:list_objects_v2, [
      { contents: [ { key: "#{@prefix}config", size: 4 } ], is_truncated: true, next_continuation_token: "next" },
      { contents: [ { key: "#{@prefix}keys/#{ID}", size: 6 } ], is_truncated: false }
    ])
    assert_refused(:backup_budget_exceeded) { repository(budget_bytes: 10).create("snapshots/#{ID}", "x") }
    assert_empty @puts
  end

  test "budget counts all prefix objects including config keys and locks" do
    small = repository(budget_bytes: 6)
    small.create("config", "ab")
    small.create("keys/#{ID}", "cd")
    small.create("locks/#{ID}", "ef")
    assert_refused(:backup_budget_exceeded) { small.create("snapshots/#{ID}", "g") }
    assert small.create("config", "ab"), "an exact retry is accepted even at budget"
    assert_refused(:backup_overwrite_refused) { small.create("config", "different") }
    small.delete_lock("locks/#{ID}")
    assert small.create("snapshots/#{ID}", "gh")
    assert_equal 6, @objects.values.sum(&:bytesize)
  end

  test "delete only locks and missing lock delete is idempotent" do
    @objects["#{@prefix}locks/#{ID}"] = "lock"
    @repository.delete_lock("locks/#{ID}")
    @repository.delete_lock("locks/#{ID}")
    assert_equal [ "#{@prefix}locks/#{ID}", "#{@prefix}locks/#{ID}" ], @deletes
    [ "config", "keys/#{ID}", "snapshots/#{ID}", "data/#{ID}", "locks/../config" ].each do |path|
      assert_refused(:bad_backup_request) { @repository.delete_lock(path) }
    end
  end

  test "oversize writes and invalid direct object paths do not touch S3" do
    assert_refused(:backup_object_too_large) { @repository.create("data/#{ID}", "x" * (Backup::VmRepository::MAX_BYTES + 1)) }
    [ "../config", "data/aa/#{ID}", "keys/" ].each do |path|
      assert_refused(:bad_backup_request) { @repository.create(path, "x") }
    end
    assert_empty @puts
  end

  test "bounded reads range errors missing objects and conditional conflict" do
    assert_refused(:backup_object_not_found) { @repository.read("config") }
    assert_refused(:bad_backup_range) { @repository.read("config", range: "bytes=0-1,3-4") }
    @client.stub_responses(:get_object, { body: "abc", content_length: 3, content_range: "bytes 0-2/100" })
    assert_equal({ body: "abc", content_range: "bytes 0-2/100" }, @repository.read("data/#{ID}", range: "bytes=0-2"))
    @client.stub_responses(:get_object, { body: "x" * (Backup::VmRepository::MAX_BYTES + 1), content_length: Backup::VmRepository::MAX_BYTES + 1 })
    assert_refused(:backup_object_too_large) { @repository.read("data/#{ID}", range: "bytes=0-") }
    @client.stub_responses(:put_object, "ConditionalRequestConflict")
    assert_refused(:backup_storage_busy) { @repository.create("config", "x") }
  end

  test "repository lock is held during S3 commit and rejects a concurrent writer" do
    key = Backup::VmRepository.lock_key("repository:synthetic-backups:#{@prefix}")
    connection = observer
    begin
      assert lock_value(connection, "SELECT pg_try_advisory_lock(#{key})")
      assert_refused(:backup_storage_busy) { @repository.create("config", "x") }
      assert_empty @puts
    ensure
      connection.close
    end
    @client.stub_responses(:put_object, lambda do |_context|
      connection = observer
      begin
        refute lock_value(connection, "SELECT pg_try_advisory_lock(#{key})")
      ensure
        connection.close
      end
      {}
    end)
    assert @repository.create("config", "x")
  end

  test "shared endpoint and enrollment slots reject excess requests and release on exceptions" do
    connection = observer
    endpoint = Backup::VmRepository.lock_key("slot:endpoint:0")
    enrollment_keys = 2.times.map { |slot| Backup::VmRepository.lock_key("slot:enrollment:999:#{slot}") }
    begin
      assert lock_value(connection, "SELECT pg_try_advisory_lock(#{endpoint})")
      assert_refused(:backup_busy) { Backup::VmRepository::Admission.with(999, limit: 1) { flunk "admitted" } }
      connection.exec("SELECT pg_advisory_unlock(#{endpoint})")
      enrollment_keys.each { |key| assert lock_value(connection, "SELECT pg_try_advisory_lock(#{key})") }
      assert_refused(:backup_busy) { Backup::VmRepository::Admission.with(999, limit: 1) { flunk "admitted" } }
      assert lock_value(connection, "SELECT pg_try_advisory_lock(#{endpoint})"), "endpoint slot is released when enrollment slots are full"
    ensure
      connection.close
    end
    assert_raises(RuntimeError) { Backup::VmRepository::Admission.with(999, limit: 1) { raise "failure" } }
    assert Backup::VmRepository::Admission.with(999, limit: 1) { true }
  end

  test "a request timeout releases both shared admission and repository locks" do
    key = Backup::VmRepository.lock_key("repository:synthetic-backups:#{@prefix}")
    entered_storage = false
    @client.stub_responses(:put_object, lambda do |_context|
      entered_storage = true
      sleep 1
      {}
    end)
    assert_raises(Timeout::Error) do
      Backup::VmRepository::Admission.with(999, limit: 1) do
        Timeout.timeout(0.1) { @repository.create("config", "x") }
      end
    end
    assert entered_storage, "timeout interrupted storage while the repository lock was held"
    connection = observer
    begin
      assert lock_value(connection, "SELECT pg_try_advisory_lock(#{key})"), "timed-out write leaves no repository lock"
      endpoint = Backup::VmRepository.lock_key("slot:endpoint:0")
      assert lock_value(connection, "SELECT pg_try_advisory_lock(#{endpoint})"), "timed-out request leaves no shared slot"
    ensure
      connection.close
    end
    @client.stub_responses(:put_object, {})
    assert Backup::VmRepository::Admission.with(999, limit: 1) { @repository.create("config", "x") }
  end

end
