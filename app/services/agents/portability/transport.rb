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

    def capture(root, output)
      resources.verify_existing!
      volume = resources.volumes.fetch(root.to_sym)
      _, _, status = Open3.capture3("docker", "volume", "inspect", volume)
      raise Error, "A required resident volume is missing" unless status.success?
      stream([ "docker", "run", "--rm", "--network", "none", "--read-only", "--mount", "type=volume,src=#{volume},dst=/data,readonly", IMAGE, "tar", "cf", "-", "-C", "/data", "." ], output: output)
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

    def command!(*args)
      _, _, status = Open3.capture3(*args)
      raise Error, "Resident storage operation failed" unless status.success?
    end

    def stream(args, output: nil, input: nil)
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
            Timeout.timeout(60) do
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
