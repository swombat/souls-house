require "aws-sdk-s3"

module Backup
  # The Telegram connector's store (its own database, comms_telegram, since
  # S2b slice 2) is backed up by the connector itself: `python -m
  # connector.backup dump` writes a sealed stream under a key derived from
  # COMMS_STORE_KEY, which Rails never holds. This job runs that inside the
  # running accessory and puts the ciphertext in the house's backup bucket,
  # beside the house dump. It is its own job so that a failure here is a
  # failed backup with its own name, while the house dump goes ahead
  # (FullBackupJob enqueues it first).
  #
  # Skipped only when the connector is deliberately off: no
  # COMMS_CONNECTOR_URL, which deploy.yml sets exactly when the Telegram image
  # is configured. A configured connector that is not running, an image too
  # old to have the command (the interval between merge and the accessory's
  # reboot), a refusal, a timeout or a short dump is a failure. Errors name a
  # reason from a fixed set or the connector's own refusal token, never the
  # command's stderr (which could name a DSN).
  class CommsTelegramDumpJob < ApplicationJob

    queue_as :default
    retry_on Aws::S3::Errors::ServiceError, wait: :polynomially_longer, attempts: 3

    class Failed < StandardError; end

    CONTAINER = "souls-house-comms-telegram".freeze
    # The dump's own deadline, inside the container: killing the `docker exec`
    # client below need not end the process Docker started there, so the dump
    # ends itself (exit 124) before this job gives up on the client.
    DEADLINE = 10.minutes
    COMMAND = [ "python", "-m", "connector.backup", "dump", "--deadline", DEADLINE.to_i.to_s ].freeze
    MAGIC = "TGBACKUP".b.freeze
    TIMEOUT = DEADLINE + 2.minutes
    INSPECT_TIMEOUT = 30.seconds
    MAX_STDERR = 64.kilobytes # the retained tail; the rest is read and dropped
    PREFIX = "comms-telegram/".freeze
    # The bucket has no lifecycle rule, so this prefix can prune itself: a
    # dump holds sealed sessions, and an owner who disconnects should not
    # stay recoverable in backups for long. Only after a new dump uploaded.
    #
    # Off until Daniel agrees the retention (asked 17 Nov, no answer yet):
    # a review can't consent to deleting backups for him. Until then every
    # dump is kept, like the house dumps beside it. Turning it on is this
    # one constant; prune! and its tests stay as written.
    PRUNE = false
    KEEP_FOR = 14.days
    KEEP_AT_LEAST = 3

    def perform
      unless ENV["COMMS_CONNECTOR_URL"].present?
        Rails.logger.info "Telegram connector backup skipped: the connector is not configured"
        return
      end
      ensure_running!
      key = "#{PREFIX}#{Time.current.utc.strftime('%Y-%m-%d_%H-%M-%S')}.tgbackup"
      Tempfile.create([ "comms-telegram", ".tgbackup" ], binmode: true) do |file|
        file.close
        summary = dump!(file.path)
        upload!(file.path, key)
        prune!(key) if PRUNE
        Rails.logger.info "Telegram connector backup completed: #{key} #{summary.to_json}"
      end
    end

    private

    def ensure_running!
      status, output = run_bounded([ "docker", "inspect", "--format", "{{.State.Running}}", CONTAINER ],
                                   timeout: inspect_timeout, reason: "inspect_timeout")
      raise Failed, "connector_not_running" unless status.success? && output.strip == "true"
    end

    # Binary stdout straight to the file; stderr drained into a bounded tail,
    # which keeps the connector's closing JSON line however much came before.
    def dump!(path)
      status, _, diagnostics = run_bounded([ "docker", "exec", CONTAINER, *COMMAND ],
                                           out_path: path, timeout: dump_timeout, reason: "dump_timeout")
      report = last_json(diagnostics)
      unless status.success?
        raise Failed, "connector_image_lacks_backup" if diagnostics.include?("No module named connector.backup")
        raise Failed, "dump_#{safe(report['refused'] || report['failed'])}" if report
        raise Failed, "dump_exit_#{status.exitstatus.to_i}"
      end
      raise Failed, "dump_unconfirmed" unless report && report["done"] == "dump"
      head = File.open(path, "rb") { |io| io.read(MAGIC.bytesize) }
      raise Failed, "dump_malformed" unless head == MAGIC
      report.slice("tables", "connections", "chunks").merge("bytes" => File.size(path))
    end

    def inspect_timeout = INSPECT_TIMEOUT
    def dump_timeout = TIMEOUT

    # Runs argv in its own process group with a deadline. Returns the status,
    # captured stdout (when no out_path; bounded like stderr) and stderr's tail.
    def run_bounded(argv, timeout:, reason:, out_path: nil)
      err_r, err_w = IO.pipe
      out_r, out_w = out_path ? [ nil, nil ] : IO.pipe
      pid = Process.spawn(*argv, in: File::NULL, out: out_path ? [ out_path, "wb" ] : out_w, err: err_w,
                          pgroup: true)
      err_w.close
      out_w&.close
      stderr_tail = String.new(encoding: Encoding::BINARY)
      stdout_tail = String.new(encoding: Encoding::BINARY)
      readers = [ Thread.new { drain_tail(err_r, stderr_tail) } ]
      readers << Thread.new { drain_tail(out_r, stdout_tail) } if out_r
      status = wait_for(pid, timeout, reason)
      [ status, stdout_tail, stderr_tail ]
    ensure
      readers&.each { |thread| thread.join(5) }
      [ err_r, err_w, out_r, out_w ].compact.each { |io| io.close unless io.closed? }
      readers&.each { |thread| thread.join(1) }
    end

    def drain_tail(io, tail)
      loop do
        tail << io.readpartial(16.kilobytes)
        tail.slice!(0, tail.bytesize - MAX_STDERR) if tail.bytesize > MAX_STDERR
      end
    rescue EOFError, IOError
      tail.force_encoding(Encoding::UTF_8).scrub!
    end

    def wait_for(pid, timeout, reason)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill("TERM", -pid) rescue nil
          sleep 2
          Process.kill("KILL", -pid) rescue nil
          Process.wait(pid) rescue nil
          raise Failed, reason
        end
        sleep 0.2
      end
    end

    def last_json(text)
      line = text.lines.map(&:strip).reject(&:empty?).last
      parsed = line && JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def safe(token)
      token.to_s[/\A[A-Za-z0-9_:.,-]{1,80}\z/] || "unknown"
    end

    def upload!(path, key)
      File.open(path, "rb") do |io|
        s3_client.put_object(bucket: bucket_name, key: key, body: io)
      end
    end

    def prune!(uploaded)
      objects = []
      token = nil
      loop do
        page = s3_client.list_objects_v2(bucket: bucket_name, prefix: PREFIX, continuation_token: token)
        objects.concat(page.contents)
        break unless page.is_truncated

        token = page.next_continuation_token
      end
      raise Failed, "prune_without_new_dump" unless objects.any? { |o| o.key == uploaded }

      newest = objects.sort_by(&:last_modified).last(KEEP_AT_LEAST).map(&:key)
      stale = objects.select { |o| o.last_modified < KEEP_FOR.ago && !newest.include?(o.key) }
      stale.each { |o| s3_client.delete_object(bucket: bucket_name, key: o.key) }
    end

    def s3_client
      @s3_client ||= begin
        creds = Rails.application.credentials.aws
        raise ArgumentError, "aws credentials not configured" if creds.blank?

        Aws::S3::Client.new(access_key_id: creds[:access_key_id], secret_access_key: creds[:secret_access_key],
                            region: creds[:s3_region])
      end
    end

    def bucket_name
      Rails.application.credentials.dig(:aws, :postgres_bucket) or
        raise ArgumentError, "aws.postgres_bucket not configured in credentials"
    end

  end
end
