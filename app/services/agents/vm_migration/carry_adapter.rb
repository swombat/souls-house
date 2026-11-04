require "socket"
require "base64"

module Agents
  class VmMigration
    # The restic REST v2 surface for ONE resident's repository, served on a
    # loopback port inside the process that is taking its carry snapshot
    # (#426 slice 3C, checkpoint 2).
    #
    # What it protects, and from whom: the resident's repository and every
    # other resident's, from the house's own carry writer. Every object
    # restic writes is one Backup::VmRepository#create, so the carry keeps
    # what a VM's own backups get: the stored-bytes recount against the
    # budget under the repository lock, no-overwrite writes (identical
    # retries pass), the per-object size cap, and the admission slots the
    # backup endpoint shares across workers. The repository is captured when
    # the adapter is made and nothing a request says can choose another.
    #
    # The lock owner. Each request runs on the adapter's own thread with its
    # own pooled database connection, so each create's
    # pg_try_advisory_xact_lock lives only for that write's own short
    # transaction. The caller (VmMigration#stage!) holds the resident's row
    # lock in a transaction on ITS connection for the whole stage; if writes
    # ran on that connection they would join it and hold the repository lock
    # until the stage ended, blocking every other writer.
    #
    # Requests are bounded (line and header sizes, header count, body size,
    # an idle limit per connection, and the adapter's deadline) and only
    # Basic auth with the per-run credential is accepted. The credential is
    # never logged, put on a command line, or put in an error.
    class CarryAdapter

      USER = "carry".freeze
      MAX_LINE = 8.kilobytes
      MAX_HEADERS = 32
      MAX_CONNECTIONS = 2
      IDLE_SECONDS = 30
      STOP_GRACE = 5
      REFUSE_DRAIN_SECONDS = 1
      WAIT_SLICE = 0.25
      PROBE = %r{\A/\.carry-probe/([0-9a-f]{32})\z}

      class Refused < StandardError; end

      Resident = Data.define(:id, :uuid)
      Response = Data.define(:status, :headers, :body)

      REPOSITORY_FACTORY = ->(resident) { Backup::VmRepository.new(agent: resident) }

      attr_reader :port, :failures, :requests

      def initialize(agent, deadline:, repository_factory: REPOSITORY_FACTORY, host: "127.0.0.1")
        @resident = Resident.new(id: agent.id, uuid: agent.uuid.to_s)
        @deadline = deadline
        @repository_factory = repository_factory
        @host = host
        @password = SecureRandom.hex(32)
        @probe = SecureRandom.hex(16)
        @failures = []
        @requests = 0
        @mutex = Mutex.new
        @handlers = []
        @sockets = []
      end

      # The URL restic is given, credential included. Callers pass it to the
      # tool through its environment only, never its argv.
      def repository_url = "rest:http://#{USER}:#{@password}@#{@host}:#{@port}/"

      # A path anyone may fetch that answers only this run's probe token: it
      # proves a tool in another container's namespace can reach this port,
      # without the credential.
      def probe_url = "http://#{@host}:#{@port}/.carry-probe/#{@probe}"
      def probe_answer = "carry-probe #{@probe}"

      def start
        @server = TCPServer.new(@host, 0)
        @port = @server.addr[1]
        @acceptor = Thread.new { accept_loop }
        @acceptor.report_on_exception = false
        self
      end

      # Always called (ensure): closes the port and every connection, and
      # waits a short grace for handlers before killing them.
      # Every accepted socket is tracked, so stop closes connections that are
      # still sending, not only the listener.
      def stop
        @stopping = true
        @server&.close rescue nil
        @acceptor&.join(STOP_GRACE) || @acceptor&.kill
        @mutex.synchronize { @sockets.dup }.each { |socket| socket.close rescue nil }
        @mutex.synchronize { @handlers.dup }.each { |thread| thread.join(STOP_GRACE) || thread.kill }
        nil
      end

      def self.open(agent, deadline:, **options)
        adapter = new(agent, deadline:, **options).start
        yield adapter
      ensure
        adapter&.stop
      end

      private

      def remaining = @deadline - Agents::BoundedCommand.now

      def accept_loop
        until @stopping
          socket = @server.accept
          if remaining <= 0 || @mutex.synchronize { @handlers.count(&:alive?) >= MAX_CONNECTIONS }
            # Refused on the acceptor itself, with no thread and no drain:
            # the short answer fits the socket buffer and the socket closes
            # at once, so busy clients can't pile up workers.
            refuse_now(socket)
            next
          end
          @mutex.synchronize do
            @handlers.reject! { |handler| !handler.alive? }
            @sockets << socket
            thread = Thread.new(socket) { |client| serve_connection(client) }
            thread.report_on_exception = false
            @handlers << thread
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def serve_connection(socket)
        loop do
          request = read_request(socket)
          break unless request

          response = respond(request)
          close = request[:headers]["connection"].to_s.casecmp?("close")
          write(socket, response, close:)
          break if close
        end
      rescue Refused
        refuse_and_close(socket, Response.new(400, {}, "bad_carry_request"))
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close rescue nil
        @mutex.synchronize { @sockets.delete(socket) }
      end

      def refuse_now(socket)
        socket.write_nonblock(head_for(Response.new(503, {}, "carry_busy"), close: true) + "carry_busy", exception: false)
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close rescue nil
      end

      # Answers, then reads (and drops) a bounded amount of what the client
      # had already sent, so closing does not reset the connection before the
      # client has read the answer. The drain has an absolute limit and
      # stops when the adapter does.
      def refuse_and_close(socket, response)
        write(socket, response, close: true)
        socket.shutdown(Socket::SHUT_WR)
        drained = 0
        ends = Agents::BoundedCommand.now + [ REFUSE_DRAIN_SECONDS, remaining ].min
        while !@stopping && drained < 1.megabyte && (left = ends - Agents::BoundedCommand.now).positive? &&
              IO.select([ socket ], nil, nil, [ left, 0.5 ].min)
          chunk = socket.read_nonblock(64.kilobytes, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable

          drained += chunk.bytesize
        end
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close rescue nil
      end

      # nil when the client closed (or went idle) between requests.
      def read_request(socket)
        line = read_line(socket, first: true)
        return nil if line.nil?

        method, target, version = line.split(" ", 3)
        raise Refused unless method&.match?(/\A[A-Z]{3,7}\z/) && target&.start_with?("/") && version&.start_with?("HTTP/1.")

        headers = {}
        lines = 0
        loop do
          header = read_line(socket) || raise(Refused)
          break if header.empty?

          # Physical lines, not distinct names: repeats count too.
          lines += 1
          raise Refused if lines > MAX_HEADERS

          name, value = header.split(":", 2)
          raise Refused unless value && name.match?(/\A[A-Za-z0-9-]+\z/)

          key = name.downcase
          raise Refused if headers.key?(key) && %w[content-length authorization].include?(key)

          headers[key] = value.strip
        end
        raise Refused if headers.key?("transfer-encoding")

        length = headers["content-length"]
        raise Refused unless length.nil? || length.match?(/\A\d{1,9}\z/)

        length = length.to_i
        raise Refused if length > Backup::VmRepository::MAX_BYTES

        { method:, target:, headers:, body: read_body(socket, length) }
      end

      def read_line(socket, first: false)
        line = +"".b
        loop do
          unless wait_readable(socket)
            return nil if first && line.empty? # idle between requests: close quietly
            raise Refused
          end
          char = socket.read_nonblock(1, exception: false)
          next if char == :wait_readable
          return nil if char.nil? && first && line.empty?
          raise Refused if char.nil?

          line << char
          raise Refused if line.bytesize > MAX_LINE
          return line.delete_suffix("\r\n") if line.end_with?("\r\n")
        end
      end

      def read_body(socket, length)
        body = +"".b
        while body.bytesize < length
          wait_readable(socket) || raise(Refused)
          chunk = socket.read_nonblock([ length - body.bytesize, 1.megabyte ].min, exception: false)
          next if chunk == :wait_readable
          raise Refused if chunk.nil?

          body << chunk
        end
        body
      end

      # Waits in short slices so stop is noticed: closing a socket does not
      # wake a thread already inside IO.select on it.
      def wait_readable(socket) = wait_for(socket, readable: true)

      def wait_for(socket, readable:)
        ends = Agents::BoundedCommand.now + [ remaining, IDLE_SECONDS ].min
        until @stopping
          left = ends - Agents::BoundedCommand.now
          return false unless left.positive?

          ready = readable ? IO.select([ socket ], nil, nil, [ left, WAIT_SLICE ].min) : IO.select(nil, [ socket ], nil, [ left, WAIT_SLICE ].min)
          return true if ready
        end
        false
      end

      def respond(request)
        @mutex.synchronize { @requests += 1 }
        if (probe = PROBE.match(request[:target]))
          return Response.new(404, {}, "") unless request[:method] == "GET" && ActiveSupport::SecurityUtils.secure_compare(probe[1], @probe)

          return Response.new(200, { "Content-Type" => "text/plain" }, probe_answer)
        end
        return Response.new(401, { "WWW-Authenticate" => 'Basic realm="carry"' }, "") unless authorized?(request[:headers]["authorization"])
        return Response.new(504, {}, "backup_timeout") if remaining <= 0

        wire_path, query = request[:target].split("?", 2)
        path = wire_path.delete_prefix("/")
        operation = Backup::VmRepository.operation(method: request[:method], path:, query: query.to_s)
        raise Backup::VmRepository::Refused.new(:unexpected_backup_body, 400) if operation != :create && request[:body].present?

        Rails.application.executor.wrap do
          ActiveRecord::Base.connection_pool.with_connection do
            Backup::VmRepository.with_database_limits do
              Backup::VmRepository::Admission.with("carry:#{@resident.id}") do
                serve(@repository_factory.call(@resident), operation, path, request)
              end
            end
          end
        end
      rescue Backup::VmRepository::Refused => error
        Response.new(error.status, {}, error.code.to_s)
      rescue ActiveRecord::QueryCanceled, ActiveRecord::LockWaitTimeout
        Response.new(503, {}, "backup_database_timeout")
      rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError
        Response.new(503, {}, "backup_storage_unavailable")
      rescue StandardError => error
        # The class only: a message could carry a URL or the request.
        @mutex.synchronize { @failures << error.class.name }
        Response.new(500, {}, "carry_adapter_error")
      end

      def authorized?(header)
        scheme, encoded = header.to_s.split(" ", 2)
        return false unless scheme&.casecmp?("basic") && encoded

        ActiveSupport::SecurityUtils.secure_compare(Base64.strict_decode64(encoded), "#{USER}:#{@password}")
      rescue ArgumentError
        false
      end

      def serve(repository, operation, path, request)
        octets = { "Content-Type" => "application/octet-stream" }
        case operation
        when :init
          repository.init!
          Response.new(200, {}, "")
        when :create
          repository.create(path, request[:body])
          Response.new(200, {}, "")
        when :delete
          repository.delete_lock(path)
          Response.new(200, {}, "")
        when :head
          Response.new(200, octets.merge("Content-Length" => repository.head(path).to_s), nil)
        when :read
          result = repository.read(path, range: request[:headers]["range"].presence)
          headers = octets.merge("Accept-Ranges" => "bytes")
          headers["Content-Range"] = result[:content_range] if result[:content_range]
          Response.new(result[:content_range] ? 206 : 200, headers, result[:body])
        when :list
          entries = repository.list(path.delete_suffix("/"))
          v2 = request[:headers]["accept"].to_s.split(",").any? { |type| type.strip.split(";").first == Backup::VmRepository::V2_MEDIA_TYPE }
          Response.new(200, { "Content-Type" => v2 ? Backup::VmRepository::V2_MEDIA_TYPE : "application/json" },
            JSON.generate(v2 ? entries : entries.pluck(:name)))
        end
      end

      REASONS = { 200 => "OK", 206 => "Partial Content", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found",
                  409 => "Conflict", 413 => "Content Too Large", 416 => "Range Not Satisfiable", 429 => "Too Many Requests",
                  500 => "Internal Server Error", 503 => "Service Unavailable", 504 => "Gateway Timeout",
                  507 => "Insufficient Storage" }.freeze

      # A HEAD answer carries the object's Content-Length and no body.
      def head_for(response, close: false)
        body = response.body.to_s.b
        headers = { "Cache-Control" => "no-store" }.merge(response.headers)
        headers["Content-Length"] ||= body.bytesize.to_s
        headers["Connection"] = "close" if close
        head = +"HTTP/1.1 #{response.status} #{REASONS.fetch(response.status, 'Error')}\r\n"
        headers.each { |name, value| head << "#{name}: #{value}\r\n" }
        head << "\r\n"
      end

      # Written without blocking: a client that stops reading can hold the
      # writer only until the idle limit or the adapter's deadline.
      def write(socket, response, close: false)
        data = head_for(response, close:).b + (response.body.nil? ? "" : response.body.to_s.b)
        offset = 0
        while offset < data.bytesize
          written = socket.write_nonblock(data.byteslice(offset, 1.megabyte), exception: false)
          if written == :wait_writable
            raise IOError, "carry client stopped reading" unless wait_for(socket, readable: false)

            next
          end
          offset += written
        end
      end

    end
  end
end
