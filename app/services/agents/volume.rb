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

    def seed_from_directory!(root)
      ensure!
      raise SeedError, "Identity volume is not empty; refusing to overwrite a home" unless empty?
      entries = {}
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next if [ ".", ".." ].include?(File.basename(path))
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        Agents::Portability::Archive.safe_path!(relative)
        stat = File.lstat(path)
        raise SeedError, "Links and special files are not supported" unless stat.file? || stat.directory?
        entries[relative] = { "type" => stat.directory? ? "directory" : "file",
          "size" => stat.size, "mode" => stat.mode & 0755 }
      end
      raise SeedError, "Seed exceeds file limit" if entries.size > Agents::GithubImportSource::MAX_FILES * 2
      Dir.mktmpdir("github-resident-seed-") do |dir|
        archive = File.join(dir, "home.tar.gz")
        Agents::Portability::Archive.pack(root, entries, archive)
        cmd = [ "docker", "run", "--rm", "-i", "-v", "#{volume_name}:/identity",
          "busybox", "sh", "-c", "tar xz -C /identity && chown -R 1000:1000 /identity" ]
        Open3.popen3(*cmd) do |stdin, _stdout, stderr, thread|
          File.open(archive, "rb") { |input| IO.copy_stream(input, stdin) }
          stdin.close
          stderr.read
          raise SeedError, "Identity seed failed; refusing automatic overwrite" unless thread.value.success?
        end
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
