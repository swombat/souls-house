require "minitest/autorun"
require "socket"
require "net/http"
require "tmpdir"
require "fileutils"
require "timeout"
require "websocket/driver"

# Standalone real-server checks: no Rails boot, database, integrations or
# resident credentials. Rails/browser CI supplies the full application checks.
class PumaUpgradeTest < Minitest::Test

  ROOT = File.expand_path("../..", __dir__)
  Wire = Struct.new(:io, :url, :env) do
    def write(data) = io.write(data)
  end

  def test_ipv4_proxy_headers_keepalive_websocket_restart_and_graceful_drain
    with_server do |port, directory|
      original = health(port)
      TCPSocket.open("127.0.0.1", port) do |http|
        3.times do
          Timeout.timeout(5) do
            http.write("GET /up HTTP/1.1\r\nHost: proxy.example.test\r\nX-Forwarded-Proto: https\r\n\r\n")
            assert_match %r{\AHTTP/1.1 200}, http.gets("\r\n")
            headers = {}
            while (line = http.gets("\r\n")) != "\r\n"
              key, value = line.split(":", 2)
              headers[key.downcase] = value.strip
            end
            assert_equal original, http.read(Integer(headers.fetch("content-length")))
            assert_equal "proxy.example.test|https", headers["x-proxy"]
            refute_equal "close", headers["connection"]
          end
        end
      end

      socket = TCPSocket.new("127.0.0.1", port)
      driver = WebSocket::Driver.client(Wire.new(socket, "ws://127.0.0.1:#{port}/cable", {}))
      opened, messages, pong = false, [], false
      driver.on(:open) { opened = true }
      driver.on(:message) { |event| messages << event.data }
      driver.start
      Timeout.timeout(5) { driver.parse(socket.readpartial(4096)) until opened }
      driver.text("upgrade-check")
      Timeout.timeout(5) { driver.parse(socket.readpartial(4096)) until messages.any? }
      assert_equal [ "upgrade-check" ], messages
      driver.ping("alive") { pong = true }
      Timeout.timeout(5) { driver.parse(socket.readpartial(4096)) until pong }
      assert pong
      socket.close

      restart = File.join(directory, "tmp/restart.txt")
      File.utime(Time.now + 1, Time.now + 1, restart)
      wait_until { health(port) != original }

      request = Thread.new { Net::HTTP.start("127.0.0.1", port, nil, read_timeout: 10) { |http| http.get("/slow") } }
      wait_until { File.exist?(File.join(directory, "slow-started")) }
      Process.kill("TERM", @server)
      assert_equal "drained", request.value.body
      assert_graceful_exit
    ensure
      socket&.close unless socket&.closed?
      request&.join(10)
    end
  end

  def test_solid_queue_plugin_forks_and_stops_with_puma
    with_server(queue: true) do |_port, directory|
      marker = File.join(directory, "queue-started")
      # File.write creates the file before writing the pid, so wait for content
      # (an empty read raced Integer() on master CI, 29 Oct).
      wait_until { File.exist?(marker) && File.read(marker).strip.match?(/\A\d+\z/) }
      queue_pid = Integer(File.read(marker).strip)
      assert_operator queue_pid, :>, 0
      refute_equal @server, queue_pid
      Process.kill("TERM", @server)
      assert_graceful_exit
      assert File.exist?(File.join(directory, "queue-stopped"))
      assert_raises(Errno::ESRCH) { Process.kill(0, queue_pid) }
    end
  end

  private

  def assert_graceful_exit
    status = Timeout.timeout(10) { Process.waitpid2(@server).last }
    @server = nil
    # Puma drains before re-raising TERM when raise_exception_on_sigterm is set.
    assert status.success? || status.termsig == Signal.list.fetch("TERM"), status.inspect
  end

  def health(port)
    Net::HTTP.start("127.0.0.1", port, nil, open_timeout: 1, read_timeout: 1) do |http|
      response = http.get("/up")
      response.value
      response.body
    end
  end

  def wait_until
    Timeout.timeout(15) do
      loop do
        begin
          return if yield
        rescue Errno::ECONNREFUSED, EOFError, Net::ReadTimeout, Net::OpenTimeout
          # Only retry startup/restart transport transitions.
        end
        sleep 0.05
      end
    end
  end

  def with_server(queue: false)
    Dir.mktmpdir("puma-upgrade-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "tmp"))
      File.write(File.join(directory, "config.ru"), rackup)
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]
      listener.close
      env = ENV.to_h.slice("PATH", "HOME", "LANG", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH")
        .merge("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "PORT" => port.to_s, "RAILS_ENV" => "test")
      env["SOLID_QUEUE_IN_PUMA"] = "1" if queue
      log = File.open(File.join(directory, "server.log"), "w+")
      @server = Process.spawn(env, "bundle", "exec", "puma", "-C", File.join(ROOT, "config/puma.rb"),
        File.join(directory, "config.ru"), chdir: directory, out: log, err: log,
        unsetenv_others: true, pgroup: true)
      wait_until { health(port) }
      yield port, directory
    rescue StandardError, Minitest::Assertion => error
      log&.rewind
      warn log&.read
      raise error
    ensure
      if @server
        begin
          Process.kill("TERM", -@server)
          Timeout.timeout(5) { Process.waitpid(@server) }
        rescue Errno::ESRCH, Errno::ECHILD
        rescue Timeout::Error
          Process.kill("KILL", -@server)
          Process.waitpid(@server)
        end
      end
      @server = nil
      log&.close
    end
  end

  def rackup
    <<~'RUBY'
      require "securerandom"
      require "active_support/core_ext/object/blank"
      require "websocket/driver"
      # Exercise the real Solid Queue Puma plugin's fork/start/stop hooks, but
      # never start job workers or connect to a database in this server probe.
      module SolidQueue
        class Supervisor
          def self.start(**)
            trap("INT") { File.write("queue-stopped", "yes"); exit }
            File.write("queue-started", Process.pid.to_s)
            sleep
          end
        end
      end
      Wire = Struct.new(:io, :env) do
        def write(data) = io.write(data)
      end
      boot = SecureRandom.hex(8)
      run lambda { |env|
        if env["PATH_INFO"] == "/cable"
          io = env["rack.hijack"].call
          Thread.new do
            driver = WebSocket::Driver.rack(Wire.new(io, env))
            driver.on(:message) { |event| driver.text(event.data) }
            driver.start
            loop { driver.parse(io.readpartial(4096)) }
          rescue EOFError, IOError, Errno::ECONNRESET
          ensure
            io.close
          end
          [ -1, {}, [] ]
        elsif env["PATH_INFO"] == "/slow"
          File.write("slow-started", "yes")
          sleep 0.5
          [ 200, { "content-type" => "text/plain" }, [ "drained" ] ]
        else
          [ 200, { "content-type" => "text/plain", "content-length" => boot.bytesize.to_s,
                   "x-proxy" => "#{env['HTTP_HOST']}|#{env['HTTP_X_FORWARDED_PROTO']}" }, [ boot ] ]
        end
      }
    RUBY
  end

end
