require "aws-sdk-s3"
require "digest"

module Backup
  # The VM gets no S3 credentials. All mutations of this prefix must go through
  # this service; the advisory lock is deliberately held across S3 operations.
  class VmRepository

    MAX_BYTES = 32.megabytes
    MAX_LIST_ENTRIES = 100_000
    MAX_REPOSITORY_OBJECTS = 1_000_000
    TYPES = %w[keys locks snapshots index data].freeze
    HASH = /\A[0-9a-f]{64}\z/
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    V2_MEDIA_TYPE = "application/vnd.x.restic.rest.v2"

    class Refused < StandardError

      attr_reader :code, :status

      def initialize(code, status)
        @code, @status = code, status
        super(code.to_s)
      end

    end

    # Paths are the REST wire layout, not the S3 layout. In particular, callers
    # cannot send the data shard themselves, escape the prefix, or choose a repo.
    def self.operation(method:, path:, query:)
      if path.empty? || path == "/"
        return :init if method == "POST" && query == "create=true"
      elsif query.empty?
        return :list if method == "GET" && TYPES.any? { |type| path == "#{type}/" }
        if path == "config" || path.match?(/\A(?:keys|locks|snapshots|index|data)\/[0-9a-f]{64}\z/)
          return :read if method == "GET"
          return :head if method == "HEAD"
          return :create if method == "POST"
          return :delete if method == "DELETE" && path.start_with?("locks/")
        end
      end
      raise Refused.new(:bad_backup_request, 400)
    end

    def initialize(agent:, client: nil, bucket: nil, budget_bytes: ENV.fetch("VM_BACKUP_BUDGET_BYTES", 20.gigabytes.to_s), deadline_seconds: 20, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise Refused.new(:invalid_backup_identity, 503) unless UUID.match?(agent.uuid.to_s)

      @agent_id = agent.id
      @prefix = "agents/#{agent.uuid}/"
      @client = client
      @bucket = bucket
      @clock = clock
      @deadline = @clock.call + deadline_seconds
      @budget_bytes = Integer(budget_bytes)
      raise ArgumentError, "backup budget must be positive" unless @budget_bytes.positive?
    end

    def init!
      # restic subsequently POSTs config and keys. No directories or mutable
      # repository metadata are created, and an existing repo is never reset.
      true
    end

    def head(path)
      storage { client.head_object(bucket:, key: object_key(path)) }.content_length
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      raise Refused.new(:backup_object_not_found, 404)
    end

    def read(path, range: nil)
      options = { bucket:, key: object_key(path) }
      if range
        raise Refused.new(:bad_backup_range, 416) unless range.match?(/\Abytes=\d+-\d*\z/)
        options[:range] = range
      else
        raise Refused.new(:backup_object_too_large, 413) if head(path) > MAX_BYTES
      end
      body = +"".b
      result = storage do
        client.get_object(**options) do |chunk|
          check_deadline!
          raise Refused.new(:backup_object_too_large, 413) if body.bytesize + chunk.bytesize > MAX_BYTES

          body << chunk
        end
      end
      raise Refused.new(:backup_object_too_large, 413) if result.content_length.to_i > MAX_BYTES

      { body:, content_range: result.content_range }
    rescue Aws::S3::Errors::NoSuchKey
      raise Refused.new(:backup_object_not_found, 404)
    rescue Aws::S3::Errors::InvalidRange
      raise Refused.new(:bad_backup_range, 416)
    end

    def list(type)
      raise Refused.new(:bad_backup_request, 400) unless TYPES.include?(type)

      entries = []
      each_object("#{@prefix}#{type}/") do |object|
        relative = object.key.delete_prefix("#{@prefix}#{type}/")
        name = type == "data" ? relative.split("/").last : relative
        expected = type == "data" ? "#{name.to_s.first(2)}/#{name}" : name
        next unless HASH.match?(name.to_s) && relative == expected

        raise Refused.new(:backup_listing_too_large, 413) if entries.size >= MAX_LIST_ENTRIES

        entries << { name:, size: object.size }
      end
      entries
    end

    def snapshot_exists?(snapshot_id)
      return false unless HASH.match?(snapshot_id.to_s)

      head("snapshots/#{snapshot_id}")
      true
    rescue Refused => error
      raise unless error.status == 404

      false
    end

    def create(path, body)
      raise Refused.new(:backup_object_too_large, 413) if body.bytesize > MAX_BYTES

      key = object_key(path)
      with_repository_lock do
        # Recount under the same lock as the commit. This avoids a DB/S3 dual
        # write counter drifting after a timeout/crash. Identical retries remain
        # allowed even when the budget is full.
        existing_size = object_size(key)
        if existing_size
          compare_existing!(path, body)
        else
          bytes = 0
          each_object(@prefix) { |object| bytes += object.size }
          if bytes + body.bytesize > @budget_bytes
            Rails.logger.error("[vm_backup] budget_exceeded agent_id=#{@agent_id} stored_bytes=#{bytes} incoming_bytes=#{body.bytesize} budget_bytes=#{@budget_bytes}")
            raise Refused.new(:backup_budget_exceeded, 507)
          end
          begin
            storage { client.put_object(bucket:, key:, body:, if_none_match: "*") }
          rescue Aws::S3::Errors::PreconditionFailed
            compare_existing!(path, body)
          rescue Aws::S3::Errors::ConditionalRequestConflict
            raise Refused.new(:backup_storage_busy, 503)
          end
        end
      end
      true
    end

    def delete_lock(path)
      raise Refused.new(:bad_backup_request, 400) unless path.match?(/\Alocks\/[0-9a-f]{64}\z/)

      with_repository_lock { storage { client.delete_object(bucket:, key: object_key(path)) } }
      true
    end

    # Fast local rejection, then shared PostgreSQL slots across Puma
    # workers/hosts. Requires session pooling:
    # transaction-mode PgBouncer cannot safely hold session advisory locks.
    class Admission

      MUTEX = Mutex.new
      COUNTS = Hash.new(0)
      PER_ENROLLMENT = 2

      def self.with(enrollment_id, limit: Integer(ENV.fetch("VM_BACKUP_MAX_IN_FLIGHT", "4")))
        raise ArgumentError, "backup concurrency limit must be positive" unless limit.positive?

        MUTEX.synchronize do
          raise Refused.new(:backup_busy, 429) if COUNTS[:all] >= limit || COUNTS[enrollment_id] >= PER_ENROLLMENT

          COUNTS[:all] += 1
          COUNTS[enrollment_id] += 1
        end
        begin
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            # These SELECTs have side effects: query caching an unlock leaks
            # slots, and caching a try-lock can admit an unprotected write.
            connection.uncached do
              locks = []
              begin
                locks << acquire_slot(connection, "endpoint", limit)
                locks << acquire_slot(connection, "enrollment:#{enrollment_id}", PER_ENROLLMENT)
                yield
              ensure
                release_locks(connection, locks)
              end
            end
          end
        ensure
          MUTEX.synchronize do
            COUNTS[:all] -= 1
            COUNTS[enrollment_id] -= 1
            COUNTS.delete(enrollment_id) if COUNTS[enrollment_id].zero?
          end
        end
      end

      def self.acquire_slot(connection, scope, count)
        count.times do |slot|
          key = VmRepository.lock_key("slot:#{scope}:#{slot}")
          return key if connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        end
        raise Refused.new(:backup_busy, 429)
      end
      private_class_method :acquire_slot

      def self.release_locks(connection, locks)
        failed = false
        locks.reverse_each do |key|
          begin
            failed = true unless connection.select_value("SELECT pg_advisory_unlock(#{key})")
          rescue StandardError
            failed = true
          end
        end
        return unless failed

        # Never return an uncertain session to the pool. Closing its socket
        # also releases locks when no unlock statement can reach PostgreSQL.
        VmRepository.discard_connection(connection)
        raise Refused.new(:backup_database_unavailable, 503) unless $!
      end
      private_class_method :release_locks

    end

    # Native PostgreSQL cancellation, not asynchronous Ruby interruption.
    # Restore session settings even when authorization/admission is refused.
    def self.with_database_limits(statement_timeout_ms: 5_000, lock_timeout_ms: 1_000)
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.uncached do
          previous = {}
          begin
            { statement_timeout: statement_timeout_ms, lock_timeout: lock_timeout_ms }.each do |name, milliseconds|
              previous[name] = connection.select_value("SHOW #{name}")
              connection.execute("SET #{name} = #{Integer(milliseconds)}")
            end
            yield
          ensure
            failed = false
            # Admission may already have discarded this adapter. Do not
            # reconnect an unmanaged socket just to restore dead-session state.
            if connection.pool.connections.include?(connection)
              previous.each do |name, value|
                begin
                  connection.execute("SET #{name} = #{connection.quote(value)}")
                rescue StandardError
                  failed = true
                end
              end
            end
            if failed
              discard_connection(connection)
              raise Refused.new(:backup_database_unavailable, 503) unless $!
            end
          end
        end
      end
    end

    def self.discard_connection(connection)
      Rails.logger.error("[vm_backup] discarding uncertain database session")
      connection.pool.remove(connection)
      connection.disconnect!
    end

    def self.lock_key(value)
      Digest::SHA256.digest("souls-house:vm-backup:#{value}").unpack1("q>")
    end

    private

    def check_deadline!
      raise Refused.new(:backup_timeout, 504) if @clock.call >= @deadline
    end

    def storage
      check_deadline!
      result = yield
      check_deadline!
      result
    end

    def compare_existing!(path, body)
      raise Refused.new(:backup_overwrite_refused, 409) unless read(path)[:body] == body
    end

    def object_key(path)
      unless path == "config" || path.match?(/\A(?:keys|locks|snapshots|index|data)\/[0-9a-f]{64}\z/)
        raise Refused.new(:bad_backup_request, 400)
      end
      relative = path.start_with?("data/") ? "data/#{path.delete_prefix('data/').first(2)}/#{path.delete_prefix('data/')}" : path
      "#{@prefix}#{relative}"
    end

    def object_size(key)
      storage { client.head_object(bucket:, key:) }.content_length
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    end

    def each_object(prefix)
      token = nil
      count = 0
      loop do
        page = storage { client.list_objects_v2(bucket:, prefix:, continuation_token: token) }
        page.contents.each do |object|
          count += 1
          raise Refused.new(:backup_repository_too_large, 503) if count > MAX_REPOSITORY_OBJECTS

          yield object
        end
        break unless page.is_truncated

        next_token = page.next_continuation_token
        raise Refused.new(:backup_storage_unavailable, 503) if next_token.blank? || next_token == token

        token = next_token
      end
    end

    def with_repository_lock
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.uncached do
          connection.transaction do
            key = self.class.lock_key("repository:#{bucket}:#{@prefix}")
            unless connection.select_value("SELECT pg_try_advisory_xact_lock(#{key})")
              raise Refused.new(:backup_storage_busy, 503)
            end
            yield
          end
        end
      end
    end

    def bucket
      @bucket ||= AgentRestic.bucket
    end

    def client
      @client ||= Aws::S3::Client.new(
        region: AgentRestic.region,
        access_key_id: AgentRestic.aws_value(:access_key_id),
        secret_access_key: AgentRestic.aws_value(:secret_access_key),
        http_open_timeout: 3, http_read_timeout: 5, retry_limit: 0
      )
    end

  end
end
