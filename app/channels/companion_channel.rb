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
      stream_for(device, coder: ActiveSupport::JSON) { |message| relay(message) }
      ready = { type: "ready", device_id: device.obfuscated_id, connection_epoch: @epoch,
        grant_revision: device.grant_revision, policy: device.policy, paused: device.paused? }
      ready.merge!(kind: "pocket", **device.consent_state) if device.pocket?
      transmit(ready)
      # A reply's voice that finished while the device was away follows
      # "ready" (CompanionDevice::Pocket); the firmware plays each clip once.
      if device.pocket? && (audio = device.pocket_audio_payload(@epoch))
        transmit(audio)
      end
    end
  end

  # The companion's report of its local ceiling, sent once after "ready".
  # Stored only while this subscription's epoch is still the device's
  # current one; anything else is dropped without a reply.
  def report_ceiling(data)
    return unless @epoch && current_companion_device.computer?

    current_companion_device.record_ceiling_report!(epoch: @epoch, claimed_epoch: data["connection_epoch"],
      ceiling: data["ceiling"], execute_lifecycle_accepted: data["execute_lifecycle_accepted"])
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

  private

  # A pocket's replies are checked once more at the socket (Mira, JnwomB):
  # stamped with the epoch they were delivered under, and sent only while
  # that is still this subscription's epoch and the device is still active.
  # A reply queued for a socket that a pause, revoke or reconnect has since
  # replaced is dropped here.
  def relay(message)
    if message.is_a?(Hash) && CompanionDevice::Pocket::GUARDED_TYPES.include?(message["type"])
      device = CompanionDevice.find_by(id: current_companion_device.id)
      return unless @epoch && message["epoch"] == @epoch && device&.active? && device.connection_epoch == @epoch
      # A consent that a later change has overtaken never goes down, so a
      # late "on" can't follow an "off" (Mira, jLQOLG).
      return if message["type"] == "consent" && message["consent_revision"] != device.consent_revision
    end
    transmit(message)
  end

end
