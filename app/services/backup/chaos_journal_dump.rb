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
  # The resident can write its own storage_url, so the URL is not trusted to
  # say whose database it is. The dump connects as the role and password the
  # URL carries, over the server's Docker network, where pg_hba requires
  # scram: PostgreSQL itself then decides what that role may read, and each
  # journal database belongs to its own role, which cannot connect to any
  # other resident's (Mira, #1006). The server's local socket and loopback are
  # trusted without a password, so the dump never runs inside its container.
  #
  # Only a database on the house's own server is dumped, never the house's
  # own, never a *_oauth one (provider auth stays out, as the state volume
  # does). A home on SQLite keeps its journal in the chaos volume, which is
  # backed up already. An unreadable or missing setting fails the backup.
  class ChaosJournalDump

    class Error < StandardError; end

    DUMP_FILE = "chaos-journal.dump"
    # The house's own bookkeeping from the 11 Nov oauth-store merge
    # (ops/chaos-home/oauth_store_merge.sql: "not resident state"). It is
    # owned by the house user, so the resident's role cannot read it, and
    # pg_dump would fail at LOCK TABLE for every merged home without this.
    EXCLUDED_TABLES = %w[public.house_oauth_store_merges].freeze
    MOUNT = "/data/chaos-db"
    RESTORED_VOLUME_SUFFIX = "chaos-db-restored"

    Target = Struct.new(:host, :port, :user, :password, :database, keyword_init: true)

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
      target = self.target
      return yield([], nil) unless target

      server = self.class.server
      volume = "#{resources.container}-chaos-db-#{SecureRandom.hex(6)}"
      labels = [ *resources.labels, "--label", "house.souls.purpose=chaos-journal-dump" ]
      created = false
      begin
        capture!("docker", "volume", "create", *labels, volume)
        created = true
        dump!(target, server, volume)
        receipt = verify!(server, volume).merge("database" => target.database)
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

    # Where the resident's Chaos keeps its journal, when that is the house's
    # own server; nil for a home without a chaos volume or on SQLite.
    def target
      chaos = resources.volumes[:chaos]
      return nil if chaos.blank?

      _, err, status = Open3.capture3("docker", "volume", "inspect", chaos)
      unless status.success?
        return nil if err.to_s.match?(/no such volume/i)
        raise Error, "Cannot inspect the chaos volume"
      end

      out, _, status = Open3.capture3("docker", "run", "--rm", "--network", "none",
        "--mount", "type=volume,src=#{chaos},dst=/chaos,readonly",
        Backup::AgentRestic::INSPECT_IMAGE, "grep", "-m1", "^storage_url", "/chaos/config.toml")
      # grep exits 1 for no matching line and 2 for an unreadable file: both
      # mean the journal's location is unknown, which is not "nothing to dump".
      raise Error, "Cannot read the resident's Chaos storage setting" unless status.success?

      self.class.target_from(out, house: self.class.house_config)
    end

    # storage_url = "postgresql://role:password@host:5432/name"
    def self.target_from(line, house:)
      value = line.to_s[/\Astorage_url\s*=\s*"([^"]*)"/, 1]
      raise Error, "Chaos storage setting is unreadable" if value.nil?
      return nil if value.start_with?("sqlite:")
      raise Error, "Chaos storage is neither SQLite nor PostgreSQL" unless value.match?(%r{\Apostgres(ql)?://})

      uri = URI.parse(value)
      raise Error, "Chaos storage is on another server" unless uri.host.present? && uri.host == house[:host]
      name = uri.path.to_s.delete_prefix("/")
      raise Error, "Chaos storage names an unexpected database" unless name.match?(/\A[a-z0-9_]{1,63}\z/)
      raise Error, "Chaos storage names a credential database" if name.match?(/_oauth(_|\z)/)
      raise Error, "Chaos storage names the house's database" if name == house[:database]
      # Percent-decoding only: a "+" in a password is a plus, not a space.
      user = URI.decode_uri_component(uri.user.to_s)
      password = URI.decode_uri_component(uri.password.to_s)
      raise Error, "Chaos storage has no credentials of its own" if user.blank? || password.blank? || user == house[:username]

      Target.new(host: uri.host, port: uri.port || 5432, user:, password:, database: name)
    rescue URI::InvalidURIError
      raise Error, "Chaos storage setting is not a valid URL"
    end

    def self.house_config
      if ENV["DATABASE_URL"].present?
        uri = URI.parse(ENV["DATABASE_URL"])
        { host: uri.host, username: uri.user, database: uri.path.delete_prefix("/") }
      else
        ActiveRecord::Base.connection_db_config.configuration_hash.slice(:host, :username, :database)
      end
    end

    # The server's own image (it has pg_dump of the server's version) and the
    # Docker network the house reaches it on.
    def self.server
      host = house_config[:host]
      out, _, status = Open3.capture3("docker", "inspect", "--format",
        "{{.Config.Image}}\t{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}", host.to_s)
      raise Error, "Cannot find the database server's container" unless status.success?

      image, networks = out.strip.split("\t", 2)
      network = networks.to_s.split.first
      raise Error, "Cannot find the database server's network" if image.blank? || network.blank?

      { image:, network: }
    end

    private

    attr_reader :agent, :resources

    # PGPASSWORD reaches the container through the environment of this
    # process (`-e PGPASSWORD` with no value), never through argv.
    def dump!(target, server, volume)
      _, err, status = Open3.capture3({ "PGPASSWORD" => target.password },
        "docker", "run", "--rm", "--network", server[:network], "-e", "PGPASSWORD",
        "-v", "#{volume}:/out", server[:image],
        "pg_dump", "-h", target.host, "-p", target.port.to_s, "-U", target.user, "-d", target.database,
        *EXCLUDED_TABLES.map { |table| "--exclude-table=#{table}" },
        "-Fc", "-Z0", "--no-owner", "--no-acl", "-f", "/out/#{DUMP_FILE}")
      return if status.success?

      reason = err.to_s.match?(/permission denied|password authentication failed|not permitted to log in/i) ?
        "the resident's role was refused" : "pg_dump failed"
      raise Error, "Chaos journal dump failed: #{reason}"
    end

    # Reads the dump back with pg_restore --list: a readable archive with the
    # journal's table data in it, not just a file that exists.
    def verify!(server, volume)
      list, _, status = Open3.capture3("docker", "run", "--rm", "--network", "none",
        "-v", "#{volume}:/in:ro", server[:image], "pg_restore", "--list", "/in/#{DUMP_FILE}")
      raise Error, "Chaos journal dump is not a readable archive" unless status.success?
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
