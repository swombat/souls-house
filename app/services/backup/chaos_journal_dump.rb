module Backup
  # Since 11 Nov 2026 a local resident's Chaos keeps its session journal
  # (journal_entries, processes, plans, crons) in its own database on the
  # house's PostgreSQL server, named by `storage_url` in the resident's
  # chaos/config.toml. Nothing else backs that database up: DatabaseBackupJob
  # dumps only the house's own database, and restic sees only volumes. This
  # dumps the resident's database, in PostgreSQL's custom format with no
  # compression of its own (restic compresses and deduplicates), into a
  # throwaway volume that the snapshot carries at /data/chaos-db.
  #
  # Only a database on the house's own server is dumped, and only the one the
  # resident's config names. A home still on SQLite keeps its journal inside
  # the chaos volume, which is backed up already. The *_oauth databases beside
  # these hold provider auth and stay out, as the state volume does.
  class ChaosJournalDump

    class Error < StandardError; end

    DUMP_FILE = "chaos-journal.dump"
    MOUNT = "/data/chaos-db"
    RESTORED_VOLUME_SUFFIX = "chaos-db-restored"

    def self.with_volume(agent, &block)
      new(agent).with_volume(&block)
    end

    def initialize(agent)
      @agent = agent
      @resources = Agents::Resources.new(agent)
    end

    # Yields the mounts for the backup command ([] when there is nothing to
    # dump) and the dump's receipt. The volume is removed afterwards.
    def with_volume
      database = database_name
      return yield([], nil) unless database

      volume = "#{resources.container}-chaos-db-#{SecureRandom.hex(6)}"
      labels = [ *resources.labels, "--label", "house.souls.purpose=chaos-journal-dump" ]
      created = false
      begin
        capture!("docker", "volume", "create", *labels, volume)
        created = true
        dump!(database, volume)
        receipt = verify!(volume).merge("database" => database)
        yield [ "-v", "#{volume}:#{MOUNT}:ro" ], receipt
      ensure
        original_error = $!
        if created
          begin
            capture!("docker", "volume", "rm", volume)
          rescue StandardError
            Rails.logger.error("Chaos journal dump volume cleanup failed: volume=#{volume}")
            raise unless original_error
          end
        end
      end
    end

    # The database the resident's Chaos uses, when it lives on the house's own
    # server; nil otherwise. Reads one line of config.toml through a read-only
    # mount with no network, and keeps only the host and the database name.
    def database_name
      chaos = resources.volumes[:chaos]
      return nil if chaos.blank?

      _, err, status = Open3.capture3("docker", "volume", "inspect", chaos)
      unless status.success?
        return nil if err.to_s.match?(/no such volume/i)
        raise Error, "Cannot inspect the chaos volume"
      end

      out, _, status = Open3.capture3("docker", "run", "--rm", "--network", "none",
        "--mount", "type=volume,src=#{chaos},dst=/chaos,readonly",
        Backup::AgentRestic::INSPECT_IMAGE, "sh", "-c",
        "grep -m1 '^storage_url' /chaos/config.toml || true")
      raise Error, "Cannot read the resident's Chaos storage setting" unless status.success?

      self.class.database_from(out, house_host:)
    end

    # "storage_url = \"postgresql://u:p@host:5432/name\"" -> "name", when host
    # is the house's server and name is a plain identifier.
    def self.database_from(line, house_host:)
      value = line.to_s[/\Astorage_url\s*=\s*"([^"]*)"/, 1]
      return nil unless value&.match?(%r{\Apostgres(ql)?://})

      uri = URI.parse(value)
      name = uri.path.to_s.delete_prefix("/")
      return nil unless uri.host.present? && uri.host == house_host
      raise Error, "Chaos storage names an unexpected database" unless name.match?(/\A[a-z0-9_]{1,63}\z/)
      raise Error, "Chaos storage names a credential database" if name.match?(/_oauth(_|\z)/) || name == house_database

      name
    rescue URI::InvalidURIError
      raise Error, "Chaos storage setting is not a valid URL"
    end

    def self.house_database
      house_config[:database]
    end

    def self.house_config
      if ENV["DATABASE_URL"].present?
        uri = URI.parse(ENV["DATABASE_URL"])
        { host: uri.host, username: uri.user, database: uri.path.delete_prefix("/") }
      else
        ActiveRecord::Base.connection_db_config.configuration_hash.slice(:host, :username, :database)
      end
    end

    private

    attr_reader :agent, :resources

    def house_host
      self.class.house_config[:host]
    end

    # pg_dump runs inside the server's container over its local socket, as the
    # house's database user, so no resident password is read or passed; its
    # output streams straight into the dump volume.
    def dump!(database, volume)
      statuses = Open3.pipeline(
        [ "docker", "exec", house_host, "pg_dump", "-U", self.class.house_config[:username].to_s,
          "-Fc", "-Z0", "--no-owner", "--no-acl", "-d", database ],
        [ "docker", "run", "--rm", "-i", "--network", "none", "-v", "#{volume}:/out",
          Backup::AgentRestic::INSPECT_IMAGE, "sh", "-c", "cat > /out/#{DUMP_FILE}" ],
        err: File::NULL
      )
      raise Error, "Chaos journal dump failed" unless statuses.all?(&:success?)
    end

    # Reads the dump back through pg_restore --list: a readable archive with
    # the journal's table data in it, not just a file that exists.
    def verify!(volume)
      list, status = Open3.pipeline_r(
        [ "docker", "run", "--rm", "--network", "none", "-v", "#{volume}:/in:ro",
          Backup::AgentRestic::INSPECT_IMAGE, "cat", "/in/#{DUMP_FILE}" ],
        [ "docker", "exec", "-i", house_host, "pg_restore", "--list" ],
        err: File::NULL
      ) { |out, threads| [ out.read, threads.map(&:value) ] }
      # pg_restore --list stops after the table of contents, so the reader
      # before it may die of a closed pipe; only pg_restore's verdict counts.
      raise Error, "Chaos journal dump is not a readable archive" unless status.last.success?
      raise Error, "Chaos journal dump has no journal" unless list.include?("TABLE DATA public journal_entries")

      { "toc_entries" => list.lines.count { |line| !line.start_with?(";") && line.strip.present? } }
    end

    def capture!(*command)
      out, err, status = Open3.capture3(*command)
      raise Error, "#{command.first(3).join(' ')} failed: #{err.to_s.squish.last(200)}" unless status.success?

      out
    end

  end
end
