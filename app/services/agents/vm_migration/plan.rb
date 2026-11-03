require "zlib"
require "tmpdir"

module Agents
  class VmMigration
    # The dry run for moving one house resident to its own server (#426,
    # slice 3B): every gate with its current answer, and each role home's
    # size against the runner's seed limits, and the whole archive against
    # Export's own limits.
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

      # The whole archive, as Export checks it: the three roles together plus
      # the memory checkpoint and legacy diary. compressed_bytes is an upper
      # bound: the roles' gzip sizes with a margin, plus the documents
      # uncompressed.
      Whole = Data.define(:entries, :expanded_bytes, :compressed_bytes, :graph_bytes, :legacy_rows, :refusal) do
        def fits? = refusal.nil?

        def to_h = { entries:, expanded_bytes:, compressed_bytes:, graph_bytes:, legacy_rows:, fits: fits?, refusal: }
      end

      Report = Data.define(:agent_id, :name, :gates, :roles, :whole, :measure_error, :facts) do
        def measured? = roles.any? && !whole.nil?
        def ready? = gates.all?(&:ok?) && measured? && measure_error.nil? && roles.all?(&:fits?) && whole.fits?

        def to_h
          { agent_id:, name:, ready: ready?,
            gates: gates.map { |gate| { name: gate.name, ok: gate.ok?, refusal: gate.refusal } },
            limits: Plan.limits, roles: roles.map(&:to_h), whole: whole&.to_h, measure_error:, facts: }
        end
      end

      def self.limits
        { compressed_bytes: Portability::Stage.max_role_bytes, unpacked_bytes: Portability::Stage.max_role_unpacked,
          entries: Portability::Stage.max_role_entries,
          archive_entries: Portability::Archive::MAX_ENTRIES - 4, archive_expanded_bytes: whole_expanded_budget,
          archive_compressed_bytes: Portability::Archive::MAX_COMPRESSED }
      end

      # Export's own budget for the roles (Export.call): the archive's expanded
      # limit less room for the graph and three JSON documents.
      def self.whole_expanded_budget
        Portability::Archive::MAX_EXPANDED - Portability::Archive::MAX_GRAPH - 3 * Portability::Archive::MAX_JSON
      end

      # Per-member tar overhead Export counts, and the margin added to the
      # roles' gzip sizes for the one archive's longer member names.
      MEMBER_OVERHEAD = 1024
      GZIP_MARGIN = 64.kilobytes

      # The transport is built only when a measurement reads the volumes.
      def initialize(migration, transport: nil)
        @migration = migration
        @transport = transport
      end

      # measure: false answers the gates only (no Docker). requested_by is
      # recorded when the volumes are read.
      def call(measure:, requested_by: nil)
        agent = @migration.agent
        roles = []
        whole = nil
        error = nil
        if measure
          begin
            roles, whole = measure_home
          rescue Portability::Error, Resources::OwnershipError => failure
            roles = []
            whole = nil
            error = failure.message
          end
          AuditLog.create!(action: "vm_migration_dry_run", user: requested_by, account: agent.account, auditable: agent,
            data: { "roles" => roles.map { |role| role.to_h.stringify_keys }, "whole" => whole&.to_h&.stringify_keys,
                    "measure_error" => error })
        end
        Report.new(agent_id: agent.id, name: agent.name, gates: @migration.gates, roles:, whole:, measure_error: error,
          facts: FACTS)
      end

      private

      def transport = @transport ||= Portability::Transport.new(@migration.agent)

      def measure_home
        Dir.mktmpdir("resident-migration-plan-") do |dir|
          File.chmod(0700, dir)
          measured = Portability::Archive::ROOTS.map { |role| measure_role(dir, role) }
          [ measured.map(&:first), whole(measured) ]
        end
      end

      # Export.call's whole-archive refusals, checked against the measured
      # roles: entry count and expanded budget exactly as Export counts them,
      # legacy diary rows, the graph's own cap, and the compressed archive as
      # an upper bound.
      def whole(measured)
        agent = @migration.agent
        all = measured.flat_map(&:last)
        entries = all.length
        expanded = all.sum { |item| item["size"] + MEMBER_OVERHEAD }
        legacy = agent.memories.count
        graph = graph_bytes(agent)
        documents = (graph.is_a?(Integer) ? graph : 0) + legacy_bytes(agent) + 64.kilobytes
        compressed = measured.sum { |role, _| role.compressed_bytes } + GZIP_MARGIN + documents
        refusal =
          if graph == :too_large then "Its memory graph is larger than an archive can carry"
          elsif legacy > 1000 then "Too many legacy diary entries for v1"
          elsif entries > Portability::Archive::MAX_ENTRIES - 4 || expanded > Plan.whole_expanded_budget
            "Resident files exceed v1 limits"
          elsif compressed > Portability::Archive::MAX_COMPRESSED
            "The whole home may be larger than an archive can carry " \
              "(#{Portability::Archive::MAX_COMPRESSED / 1.megabyte} MB compressed)"
          end
        Whole.new(entries:, expanded_bytes: expanded, compressed_bytes: compressed,
          graph_bytes: graph == :too_large ? nil : graph, legacy_rows: legacy, refusal:)
      end

      def graph_bytes(agent)
        return nil unless agent.memory_vault

        JSON.generate(Mnemodyne::Checkpoint.export(agent.memory_vault)).bytesize
      rescue Mnemodyne::Checkpoint::Invalid
        :too_large
      end

      def legacy_bytes(agent)
        JSON.generate(agent.memories.order(:id).limit(1001).map { |m| m.attributes.slice(*Portability::Archive::LEGACY_FIELDS).as_json }).bytesize
      end

      def measure_role(dir, role)
        stage = File.join(dir, role)
        Dir.mkdir(stage, 0700)
        raw = File.join(dir, "#{role}.tar")
        File.open(raw, "wb", 0600) { |out| transport.capture(role, out) }
        root = "resident/#{role}"
        entries = { root => { "type" => "directory", "mode" => 0700, "size" => 0, "sha256" => nil } }
        entries.merge!(Portability::Archive.unpack(raw, stage, prefix: root))
        File.delete(raw)

        archive = Portability::Archive.new(stage, entries)
        members = entries.select { |path, _| path.start_with?("#{root}/") }
        unpacked = members.sum { |_, item| item["type"] == "file" ? item["size"] : 0 }
        compressed = compressed_size(archive, role)
        role_report = Role.new(role:, compressed_bytes: compressed, unpacked_bytes: unpacked, entries: members.length,
          refusal: refusal_for(archive, role, compressed))
        [ role_report, entries.values ]
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
