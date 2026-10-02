module Agents::Portability
  class Export

    def self.unavailable_reason(agent)
      return "V1 supports native house residents only; external graphs/imported homes are not migrated" if agent.imported_home?
      return "V1 requires an inactive, paused hosted resident" unless agent.externally_hosted? && !agent.active? && agent.paused? && agent.uuid.present?
      return "Resident has pending or uncertain execution" if ResidentTurn.pending.where(agent: agent).exists? || agent.agent_runtime_interactions.where(finished_at: nil).exists?
      return "V1 cannot export a deliberately erased graph; its disable intent must not be lost" if agent.memory_erased_at? && !agent.memory_vault
      return "Memory erasure is pending" if agent.memory_vault&.erasure_requested_at?
      return "Memory is suspended; resolve its checkpoint first" if agent.memory_vault&.suspended_at?
      nil
    end

    def self.call(agent, exporter:, transport: Transport.new(agent))
      Dir.mktmpdir("resident-export-") do |dir|
        File.chmod(0700, dir)
        stage = File.join(dir, "stage")
        Dir.mkdir(stage, 0700)
        entries = {}
        manifest = nil
        agent.with_lock do
          raise Error, unavailable_reason(agent) if unavailable_reason(agent)
          transport.stopped!
          snapshot = -> do
            # One bounded source-only SELECT establishes the legacy diary cutoff.
            legacy = agent.memories.order(:id).limit(1001).map { |m| m.attributes.slice(*Archive::LEGACY_FIELDS).as_json }
            raise Error, "Too many legacy diary entries for v1" if legacy.length > 1000
            Archive::ROOTS.each do |root|
              path = "resident/#{root}"
              FileUtils.mkdir_p(File.join(stage, path), mode: 0700)
              entries[path] = { "type" => "directory", "mode" => 0700, "size" => 0, "sha256" => nil }
              raw = File.join(dir, "#{root}.tar")
              File.open(raw, "wb", 0600) { |out| transport.capture(root, out) }
              entries.merge!(Archive.unpack(raw, stage, prefix: path))
              raise Error, "Resident files exceed v1 limits" if entries.length > Archive::MAX_ENTRIES - 4 || entries.values.sum { |v| v["size"] + 1024 } > Archive::MAX_EXPANDED - Archive::MAX_GRAPH - 3 * Archive::MAX_JSON
            end
            graph = agent.memory_vault && Mnemodyne::Checkpoint.export(agent.memory_vault)
            add_json(stage, entries, "memory/checkpoint.json", graph) if graph
            add_json(stage, entries, "memory/legacy.json", legacy)
            add_file(stage, entries, "README.md", readme)
            manifest = {
              "format" => Archive::FORMAT, "export_id" => SecureRandom.uuid,
              "created_at" => Time.current.iso8601, "source_application" => "souls.house",
              "source_resident_id" => agent.uuid,
              "source_installation" => Digest::SHA256.hexdigest(Agents::Config.internal_url),
              "exported_by" => exporter.to_param.to_s,
              "home_profile" => "house", "memory_backend" => graph ? "native" : "absent",
              "metadata" => agent.attributes.slice(*Archive::METADATA).as_json,
              "included_roots" => Archive::ROOTS, "excluded_roots" => %w[chaos state conversations],
              "warnings" => Archive::WARNINGS, "inventory" => entries.deep_dup
            }
            add_json(stage, entries, "manifest.json", manifest)
            transport.stopped!
            raise Error, "Resident became busy during export" if ResidentTurn.pending.where(agent: agent).exists? || agent.agent_runtime_interactions.where(finished_at: nil).exists?
          end
          agent.memory_vault ? agent.memory_vault.with_lock(&snapshot) : snapshot.call
        end
        output = File.join(dir, "resident.tar.gz")
        Archive.pack(stage, entries, output)
        # Revalidate our own output, using the same hostile-input boundary.
        File.open(output, "rb") { |file| Archive.with_upload(file) { |_| } }
        # Private-data download custody, not resident-authored memory.
        AuditLog.create!(action: "export_resident_archive", user: exporter, account: agent.account, auditable: agent,
          data: manifest.slice("export_id", "created_at", "source_resident_id", "source_installation"))
        yield output
      end
    end

    def self.add_json(stage, entries, path, object)
      body = JSON.generate(object)
      raise Error, "Resident metadata exceeds v1 limit" if body.bytesize > (path == "memory/checkpoint.json" ? Archive::MAX_GRAPH : Archive::MAX_JSON)
      add_file(stage, entries, path, body)
    end

    def self.add_file(stage, entries, path, body)
      FileUtils.mkdir_p(File.dirname(File.join(stage, path)), mode: 0700)
      File.write(File.join(stage, path), body, mode: "wb", perm: 0600)
      entries[path] = { "type" => "file", "mode" => 0600, "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body) }
    end

    def self.readme
      <<~TEXT
        souls.house resident archive v1 (souls-resident/v1)

        #{Archive::WARNINGS.join("\n\n")}

        Included: actual identity, repository and work volumes, safe file modes,
        native logical Mnemodyne nodes/edges/settings, and resident-only legacy
        AgentMemory diary entries. Graph source pointers may refer to uncopied
        external material. Native embeddings are derived and will be rebuilt.
        Backend absent means no native vault, NOT an external graph export.
        Imported-home/external graph profiles are unsupported in v1.

        Excluded: Chaos/state credential and session volumes, conversations,
        chat membership, provider auth, service access, integrations, process
        ledgers, automatic schedules and installation-local trust/approvals.
        Files in included authored roots may themselves contain secrets.
        Offline copies cannot enforce later erasure on unrelated installations.

        manifest.json inventories all payload members with SHA-256 checksums.
        memory/checkpoint.json uses Mnemodyne checkpoint v1; memory/legacy.json
        holds resident-only legacy diary values, not conversation transcripts.
        Files can be read offline without souls.house. Do not run archived code
        or hooks merely to inspect this archive. Import through the authenticated
        resident import page into a fresh paused/inactive resident. Graph IDs and
        owner IDs are remapped, never merged into the source. Reconnect services,
        review hook sources and establish local trust before explicitly starting.
        V1 caps: 100 MiB compressed, 512 MiB expanded, 20,000 entries, 64 MiB/file,
        8 MiB/JSON document (graph: 50 MB); no links or special files. Safe modes strip privilege
        and group/world write bits. V1 exports require stopped, inactive, paused
        source with no pending/unknown turns. Do not restart the Docker daemon
        during export; normal stopped containers are accepted.
      TEXT
    end

  end
end
