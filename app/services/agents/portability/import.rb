module Agents::Portability
  class Import

    def self.call(archive, account:, user:, name:, transport_factory: ->(agent) { Transport.new(agent) })
      archive.validate!
      raise Error, "Choose a destination name" unless name.is_a?(String) && name.present? && name.length <= 100
      manifest = archive.manifest
      transport = nil
      imported_agent = nil
      success = false
      result = Agent.transaction do
        # With new residents on their own VM, the copy is staged for one
        # instead of restored here (docs/2026-10-10-vm-imports.md): its three
        # role homes are kept in the house and its placement says it runs on
        # a VM, so nothing local ever starts it. No server is bought and no
        # cap slot taken; Activate admits it. Read here, not before
        # validation, because the switch may have changed during it.
        on_vm = Agents::VmBirthPolicy.current.enabled?

        # This is not a birth; no orientation, schedules or runtime job.
        custody = manifest.slice("export_id", "source_resident_id", "source_installation", "exported_by", "created_at")
        custody.merge!("imported_at" => Time.current.iso8601, "imported_by" => user.to_param.to_s, "source_preferences" => manifest["metadata"].slice("scheduled_wakes_enabled"))
        agent = imported_agent = account.agents.new(manifest["metadata"].except("name", "scheduled_wakes_enabled"))
        agent.assign_attributes(name: name, runtime: "provisioning", active: false, paused: true, scheduled_wakes_enabled: false, home_profile: "house", portability_custody: custody)
        if on_vm
          agent.uuid ||= SecureRandom.uuid_v7
          agent.save!
          AgentPlacement.create!(agent:, backend: "hetzner_cloud", kind: "archive_import", state: "staged")
        end
        # A VM placement makes this the remote preparation: credentials, no
        # sandbox host or local resources.
        Agents::HostedProvisioning.new(agent: agent, user: user).prepare!(started_at: Time.current)
        if on_vm
          Stage.persist!(archive, agent)
        else
          transport = transport_factory.call(agent)
          transport.create_volumes!
          Archive::ROOTS.each do |root|
            tar_path = File.join(archive.stage, "restore-#{root}.tar")
            File.open(tar_path, "wb", 0600) { |out| archive.write_role_tar(root, out) }
            transport.restore(root, tar_path)
          end
        end
        mapping = archive.graph ? GraphImport.call(agent, archive.graph, source_installation: manifest.fetch("source_installation")) : {}
        archive.legacy.each { |attributes| agent.memories.create!(attributes) }
        # direct columns deliberately bypass model-change orientation callbacks.
        # A staged home is on no volume yet; the VM path sets this once seeded.
        agent.update_columns(runtime: "offline", identity_seeded_at: on_vm ? nil : Time.current,
          portability_custody: custody.merge("graph_id_map" => mapping))
        agent.refresh_provider_presentation
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
