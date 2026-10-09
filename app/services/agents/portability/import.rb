module Agents::Portability
  class Import

    def self.call(archive, account:, user:, name:, transport_factory: ->(agent) { Transport.new(agent) })
      # An import makes a new home on this house. With new residents on their
      # own VM, that's refused rather than done locally.
      refusal = Agents::VmBirthPolicy.current.refusal(kind: :import)
      raise Error, refusal if refusal

      archive.validate!
      raise Error, "Choose a destination name" unless name.is_a?(String) && name.present? && name.length <= 100
      manifest = archive.manifest
      transport = nil
      imported_agent = nil
      success = false
      result = Agent.transaction do
        # This is not a birth; no orientation, schedules or runtime job.
        custody = manifest.slice("export_id", "source_resident_id", "source_installation", "exported_by", "created_at")
        custody.merge!("imported_at" => Time.current.iso8601, "imported_by" => user.to_param.to_s, "source_preferences" => manifest["metadata"].slice("scheduled_wakes_enabled"))
        agent = imported_agent = account.agents.new(manifest["metadata"].except("name", "scheduled_wakes_enabled"))
        agent.assign_attributes(name: name, runtime: "provisioning", active: false, paused: true, scheduled_wakes_enabled: false, home_profile: "house", portability_custody: custody)
        Agents::HostedProvisioning.new(agent: agent, user: user).prepare!(started_at: Time.current)
        transport = transport_factory.call(agent)
        transport.create_volumes!
        Archive::ROOTS.each do |root|
          tar_path = File.join(archive.stage, "restore-#{root}.tar")
          File.open(tar_path, "wb", 0600) do |out|
            Gem::Package::TarWriter.new(out) do |tar|
              prefix = "resident/#{root}/"
              archive.entries.each do |path, item|
                next unless path.start_with?(prefix)
                relative = path.delete_prefix(prefix)
                if item["type"] == "directory"
                  tar.mkdir(relative, item["mode"])
                else
                  tar.add_file_simple(relative, item["mode"], item["size"]) { |destination| File.open(File.join(archive.stage, path), "rb") { |input| IO.copy_stream(input, destination) } }
                end
              end
            end
          end
          transport.restore(root, tar_path)
        end
        mapping = archive.graph ? GraphImport.call(agent, archive.graph, source_installation: manifest.fetch("source_installation")) : {}
        archive.legacy.each { |attributes| agent.memories.create!(attributes) }
        # direct columns deliberately bypass model-change orientation callbacks.
        agent.update_columns(runtime: "offline", identity_seeded_at: Time.current,
          portability_custody: custody.merge("graph_id_map" => mapping))
        agent.memory_vault&.update_columns(suspended_at: nil)
        agent
      end
      success = true
      result
    rescue StandardError => error
      # A notification callback can fail after the database committed. Never
      # delete the already-committed copy's storage in that case.
      if imported_agent&.id && Agent.where(id: imported_agent.id).exists?
        success = true
        raise Error, "Copy restored inactive/paused, but completion notification failed. Check the residents list before retrying"
      end
      raise error if error.is_a?(Error)
      raise Error, "Resident import failed; no runnable resident was created"
    ensure
      transport&.cleanup! unless success
    end

  end
end
