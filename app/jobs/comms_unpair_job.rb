# Retries every WhatsApp disconnect the connector has not confirmed
# (ServiceConnection#unpair_pending?), until it does. Recurring; see
# config/recurring.yml. A connector that is not configured does not count
# as confirmed: the accessory outlives Rails deploys and configuration, so
# missing settings cannot prove its device is gone (Mira, #340 review 2).
class CommsUnpairJob < ApplicationJob

  queue_as :default

  def perform
    ServiceConnection.where(provider: "whatsapp", status: "revoked")
                     .where("connector_state -> 'unpair' IS NOT NULL")
                     .find_each(&:retry_unpair!)
  end

end
