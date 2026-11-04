require "open3"
require "timeout"

module Agents::Portability
  # Only disposable busybox runs; never execute code from the resident/archive.
  class Transport

    IMAGE = "busybox:1.37"
    def initialize(agent)
      @agent = agent
    end

    def stopped!
      resources.verify_existing!
      output, error, status = Open3.capture3("docker", "container", "inspect", "--format", "{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}", resources.container)
      if status.success?
        # Normal docker stop suppresses restart-policy restarts until explicit start.
        raise Error, "Stop the resident before export" unless output.split.first.in?(%w[exited created])
      elsif !error.match?(/No such (?:object|container)/i)
        raise Error, "Resident runtime state cannot be verified"
      end
      true
    end

    def idle!
      resources.verify_existing!
      output, error, status = Open3.capture3("docker", "container", "inspect", "--format", "{{.State.Status}}", resources.container)
      return true if !status.success? && error.match?(/No such (?:object|container)/i)
      raise Error, "Resident runtime state cannot be verified" unless status.success?
      return true if output.strip.in?(%w[exited created])
      raise Error, "Resident runtime state is uncertain" unless output.strip == "running"
      _, _, probe = Open3.capture3("docker", "exec", resources.container, "pgrep", "-f", "chaos exec")
      raise Error, "Resident runtime is executing a turn" if probe.success?
      raise Error, "Resident execution state cannot be verified" unless probe.exitstatus == 1
      true
    end

    # timeout bounds this whole copy: the ownership and volume inspects and
    # the stream share it (a caller with its own deadline passes what is
    # left of it).
    def capture(root, output, timeout: 60)
      within(timeout) do |deadline|
        volume = inspected_volume(root.to_sym, deadline)
        stream([ "docker", "run", "--rm", "--network", "none", "--read-only", "--mount", "type=volume,src=#{volume},dst=/data,readonly", IMAGE, "tar", "cf", "-", "-C", "/data", "." ],
          output: output, timeout: left(deadline))
      end
    end

    # The runtime volumes a move must carry (#426 slice 3C), measured without
    # opening a file: how many files and bytes, which of the named paths
    # exist, and how many entries the shim's session map holds. Read-only,
    # no network, a disposable busybox like capture.
    INVENTORY_ROOTS = %i[chaos state].freeze
    INVENTORY_PROBES = {
      chaos: %w[chaos.sqlite helixkit-sessions oauth-runtime oauth-runtime/chaos.sqlite auth.json config.toml],
      state: %w[claude antigravity tailscale]
    }.freeze
    # set -e with pipefail: a failed find or stat (a file vanishing, a
    # directory it can't read) fails the whole inventory instead of being
    # counted as a smaller home. Each file prints only its size (%s) or a
    # literal x, never its name, so no filename reaches the output.
    INVENTORY_SCRIPT = <<~'SH'.freeze
      set -eo pipefail
      cd /data
      find . -type f -exec stat -c %s {} + | awk 'BEGIN { n = 0; s = 0 } { n++; s += $1 } END { printf "files %d\nbytes %.0f\n", n, s }'
      for p in "$@"; do if [ -e "./$p" ]; then echo "has $p"; fi; done
      if [ -d ./helixkit-sessions ]; then
        count=$(find ./helixkit-sessions -type f -exec stat -c x {} + | wc -l)
        echo "sessions $count"
      fi
    SH
    INVENTORY_SECONDS = 300

    # timeout bounds the whole inventory, inspects included, as for capture.
    def inventory(root, timeout: INVENTORY_SECONDS)
      root = root.to_sym
      raise Error, "Unsupported runtime volume" unless INVENTORY_ROOTS.include?(root)

      within(timeout) do |deadline|
        volume = inspected_volume(root, deadline)
        probes = INVENTORY_PROBES.fetch(root)
        output = StringIO.new
        stream([ "docker", "run", "--rm", "--network", "none", "--read-only", "--mount", "type=volume,src=#{volume},dst=/data,readonly",
                 IMAGE, "sh", "-c", INVENTORY_SCRIPT, "sh", *probes ], output:, timeout: left(deadline))
        self.class.parse_inventory(output.string, probes)
      end
    end

    # Strict: anything but the lines the script prints is a refusal, never a
    # guess.
    def self.parse_inventory(text, probes)
      refuse = -> { raise Error, "Resident runtime state cannot be measured" }
      result = { files: nil, bytes: nil, present: [], sessions: nil }
      text.each_line(chomp: true) do |line|
        case line
        when /\A(files|bytes|sessions)\s+(\d+)\z/
          key = Regexp.last_match(1).to_sym
          refuse.call unless result[key].nil?
          result[key] = Integer(Regexp.last_match(2), 10)
        when /\Ahas (\S+)\z/
          probe = Regexp.last_match(1)
          refuse.call unless probes.include?(probe) && result[:present].exclude?(probe)
          result[:present] << probe
        else refuse.call
        end
      end
      refuse.call if result[:files].nil? || result[:bytes].nil?

      result
    end

    def create_volumes!
      @created = []
      resources.verify_existing!
      Archive::ROOTS.each do |root|
        volume = resources.volumes.fetch(root.to_sym)
        _, error, status = Open3.capture3("docker", "volume", "inspect", volume)
        raise Error, "Destination storage already exists" if status.success?
        raise Error, "Destination storage cannot be verified" unless error.match?(/No such (?:object|volume)/i)
        command!("docker", "volume", "create", *resources.labels, volume)
        @created << volume
      end
    end

    def restore(root, tar_path)
      resources.verify_existing!
      volume = resources.volumes.fetch(root.to_sym)
      File.open(tar_path, "rb") do |input|
        stream([ "docker", "run", "--rm", "-i", "--network", "none", "--read-only", "--mount", "type=volume,src=#{volume},dst=/data", IMAGE, "sh", "-c", "tar xf - -C /data && chown -R 1000:1000 /data" ], input: input)
      end
    end

    def cleanup!
      Array(@created).reverse_each { |volume| command!("docker", "volume", "rm", volume) }
    end

    private

    def resources = @resources ||= Agents::Resources.new(@agent)

    TIMED_OUT = "Reading the resident's volumes ran out of time".freeze

    # One deadline for everything the block runs; an inspect still running
    # when it passes is killed (BoundedCommand), and the stream gets only
    # what is left.
    def within(timeout)
      yield Agents::BoundedCommand.now + timeout
    rescue Agents::BoundedCommand::TimedOut
      raise Error, TIMED_OUT
    end

    def left(deadline)
      remaining = deadline - Agents::BoundedCommand.now
      raise Agents::BoundedCommand::TimedOut if remaining <= 0

      remaining
    end

    def inspected_volume(root, deadline)
      resources.verify_existing!(deadline:)
      volume = resources.volumes.fetch(root)
      _, _, status = Agents::BoundedCommand.capture3("docker", "volume", "inspect", volume, deadline:)
      raise Error, "A required resident volume is missing" unless status.success?

      volume
    end

    def command!(*args)
      _, _, status = Open3.capture3(*args)
      raise Error, "Resident storage operation failed" unless status.success?
    end

    def stream(args, output: nil, input: nil, timeout: 60)
      carrier = "#{resources.container}-portable-#{SecureRandom.hex(8)}"
      args = args.dup
      args.insert(2, "--name", carrier, *resources.labels, "--label", "house.souls.purpose=resident-portability")
      begin
        Open3.popen3(*args, pgroup: true) do |stdin, stdout, stderr, process|
          writer = Thread.new do
            IO.copy_stream(input, stdin) if input
          rescue Errno::EPIPE
            nil
          ensure
            stdin.close
          end
          errors = Thread.new do
            # Drain without retaining/logging private transport errors.
            while stderr.read(64.kilobytes); end
          end
          begin
            Timeout.timeout(timeout) do
              count = 0
              while (chunk = stdout.read(64.kilobytes))
                count += chunk.bytesize
                raise Error, "Resident files exceed v1 expanded limit" if count > Archive::MAX_EXPANDED
                output&.write(chunk)
              end
              writer.value
              raise Error, "Resident storage transport failed" unless process.value.success?
            end
          ensure
            if process.alive?
              Process.kill("KILL", -process.pid)
              process.join
            end
            writer.join
            errors.join
          end
        end
      ensure
        remove_carrier!(carrier)
      end
    rescue Timeout::Error, SystemCallError
      raise Error, "Resident storage transport failed"
    end

    def remove_carrier!(name)
      # Killing the client is not sufficient: remove the uniquely-owned remote
      # container too, even if --rm already removed it after successful exit.
      Open3.popen3("docker", "rm", "-f", name, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output = Thread.new { stdout.read }
        errors = Thread.new { stderr.read(64.kilobytes) }
        begin
          Timeout.timeout(15) do
            message = errors.value
            raise Error, "Disposable transport cleanup failed" unless process.value.success? || message.match?(/No such container/i)
          end
        ensure
          if process.alive?
            Process.kill("KILL", -process.pid)
            process.join
          end
          output.join
          errors.join
        end
      end
    end

  end
end
