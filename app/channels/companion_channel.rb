class CompanionChannel < ApplicationCable::Channel

  def self.companion_device_channel?
    true
  end

  def subscribed
    device = current_companion_device
    return reject unless device

    device.with_lock do
      return reject unless device.revoked_at.nil? && !device.paused? && !device.account.reload.disabled?

      if device.connection_epoch.present?
        AuditLog.create!(account: device.account, auditable: device,
          action: "companion.device.epoch_takeover", data: { device_id: device.obfuscated_id, level: "info" })
      end
      CompanionOperation.where(companion_device: device, state: CompanionOperation::ACTIVE_STATES).update_all(state: "lost", outcome: "changed")
      @epoch = SecureRandom.uuid
      device.update!(connection_epoch: @epoch)
      stream_for device
      transmit({ type: "ready", device_id: device.obfuscated_id, connection_epoch: @epoch,
        grant_revision: device.grant_revision, policy: device.policy, paused: device.paused? })
    end
  end

  def unsubscribed
    return unless @epoch

    current_companion_device.with_lock do
      if current_companion_device.connection_epoch == @epoch
        current_companion_device.update!(connection_epoch: nil)
        CompanionOperation.where(companion_device: current_companion_device, state: CompanionOperation::ACTIVE_STATES)
          .update_all(state: "lost", outcome: "changed")
      end
    end
    stop_all_streams
  end

end
