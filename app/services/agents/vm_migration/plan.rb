require "zlib"
require "tmpdir"

module Agents
  class VmMigration
    # The dry run for moving one house resident to its own server (#426,
    # slice 3B): every gate with its current answer, and each role home's
    # size against the runner's seed limits.
    #
    # What it protects, and from whom: the resident, from an operator who
    # would otherwise find out a limit at the copy. It changes nothing: it
    # does not stop, pause, stage or buy. The sizes come from the same code
    # the real copy uses (Transport.capture, Archive.unpack,
    # Stage.check_unpacked!, a gzip of Archive#write_role_tar), into a private
    # temporary directory that is removed when it returns. A running resident
    # can be measured: its volumes are mounted read-only, so the numbers are
    # of a moving home and the real copy, taken stopped, can differ.
    class Plan

      # Stated, not switched: a dry run can't make either of these true.
      FACTS = [
        "No live move until rollback after cutover is built (#426 slice 3C). Until then a move can only be " \
        "undone before its server takes over.",
        "The Chaos and state volumes are not carried. Identity, repository and work move; runtime sessions and " \
        "provider sign-ins start fresh on the server."
      ].freeze

      Role = Data.define(:role, :compressed_bytes, :unpacked_bytes, :entries, :refusal) do
        def fits? = refusal.nil?

        def to_h = { role:, compressed_bytes:, unpacked_bytes:, entries:, fits: fits?, refusal: }
      end

      Report = Data.define(:agent_id, :name, :gates, :roles, :measure_error, :facts) do
        def measured? = roles.any?
        def ready? = gates.all?(&:ok?) && measured? && measure_error.nil? && roles.all?(&:fits?)

        def to_h
          { agent_id:, name:, ready: ready?,
            gates: gates.map { |gate| { name: gate.name, ok: gate.ok?, refusal: gate.refusal } },
            limits: Plan.limits, roles: roles.map(&:to_h), measure_error:, facts: }
        end
      end

      def self.limits
        { compressed_bytes: Portability::Stage.max_role_bytes, unpacked_bytes: Portability::Stage.max_role_unpacked,
          entries: Portability::Stage.max_role_entries }
      end

      def initialize(migration, transport: Portability::Transport.new(migration.agent))
        @migration = migration
        @transport = transport
      end

      # measure: false answers the gates only (no Docker). requested_by is
      # recorded when the volumes are read.
      def call(measure:, requested_by: nil)
        agent = @migration.agent
        roles = []
        error = nil
        if measure
          begin
            roles = measure_roles
          rescue Portability::Error => failure
            roles = []
            error = failure.message
          end
          AuditLog.create!(action: "vm_migration_dry_run", user: requested_by, account: agent.account, auditable: agent,
            data: { "roles" => roles.map { |role| role.to_h.stringify_keys }, "measure_error" => error })
        end
        Report.new(agent_id: agent.id, name: agent.name, gates: @migration.gates, roles:, measure_error: error,
          facts: FACTS)
      end

      private

      def measure_roles
        Dir.mktmpdir("resident-migration-plan-") do |dir|
          File.chmod(0700, dir)
          Portability::Archive::ROOTS.map { |role| measure_role(dir, role) }
        end
      end

      def measure_role(dir, role)
        stage = File.join(dir, role)
        Dir.mkdir(stage, 0700)
        raw = File.join(dir, "#{role}.tar")
        File.open(raw, "wb", 0600) { |out| @transport.capture(role, out) }
        root = "resident/#{role}"
        entries = { root => { "type" => "directory", "mode" => 0700, "size" => 0, "sha256" => nil } }
        entries.merge!(Portability::Archive.unpack(raw, stage, prefix: root))
        File.delete(raw)

        archive = Portability::Archive.new(stage, entries)
        members = entries.select { |path, _| path.start_with?("#{root}/") }
        unpacked = members.sum { |_, item| item["type"] == "file" ? item["size"] : 0 }
        compressed = compressed_size(archive, role)
        Role.new(role:, compressed_bytes: compressed, unpacked_bytes: unpacked, entries: members.length,
          refusal: refusal_for(archive, role, compressed))
      ensure
        FileUtils.rm_rf(stage) if stage
      end

      def refusal_for(archive, role, compressed)
        Portability::Stage.check_unpacked!(archive, role)
        return nil if compressed <= Portability::Stage.max_role_bytes

        "The #{role} home is larger than a resident server can be seeded with " \
          "(#{Portability::Stage.max_role_bytes / 1.megabyte} MB compressed)"
      rescue Portability::Error => error
        error.message
      end

      def compressed_size(archive, role)
        sink = ByteCounter.new
        gz = Zlib::GzipWriter.new(sink)
        archive.write_role_tar(role, gz)
        gz.finish
        sink.bytes
      end

      # Counts what gzip would write, keeping none of it.
      class ByteCounter

        attr_reader :bytes

        def initialize = @bytes = 0

        def write(*chunks)
          chunks.sum { |chunk| chunk.bytesize.tap { |size| @bytes += size } }
        end

        def flush = self

      end

    end
  end
end
