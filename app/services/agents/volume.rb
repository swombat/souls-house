module Agents
  class Volume

    class SeedError < StandardError; end

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    def ensure!
      Agents::Resources.new(agent).verify_existing!
      return true if system("docker", "volume", "inspect", volume_name, out: File::NULL, err: File::NULL)
      system("docker", "volume", "create", *Agents::Resources.new(agent).labels, volume_name) || raise(SeedError, "failed to create docker volume #{volume_name}")
    end

    def seed_from_exporter!
      ensure!
      raise SeedError, "identity volume #{volume_name} is not empty" unless empty?

      tarball = AgentIdentityExporter.new(agent).build
      cmd = [ "docker", "run", "--rm", "-i", "-v", "#{volume_name}:/identity", "busybox", "tar", "xz", "-C", "/identity" ]
      Open3.popen3(*cmd) do |stdin, _stdout, stderr, wait_thr|
        stdin.binmode
        stdin.write(tarball)
        stdin.close
        err = stderr.read
        raise SeedError, err.presence || "failed to seed #{volume_name}" unless wait_thr.value.success?
      end
    end

    def empty?
      Agents::Resources.new(agent).verify_existing!
      cmd = [
        "docker", "run", "--rm", "-v", "#{volume_name}:/identity:ro", "busybox", "sh", "-c",
        "test -z \"$(find /identity -mindepth 1 -print -quit)\""
      ]
      system(*cmd, out: File::NULL, err: File::NULL)
    end

    def seeded?
      !empty?
    end

    def destroy!
      Agents::Resources.new(agent).verify_existing!
      system("docker", "volume", "rm", "-f", volume_name)
    end

    def volume_name
      Agents::Resources.new(agent).volumes.fetch(:identity)
    end

  end
end
