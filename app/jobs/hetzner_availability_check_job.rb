# Asks Hetzner, every five minutes, which locations can sell the small shared
# server types, and keeps the answer (HetznerAvailabilitySample). One request,
# a short timeout and no retries: a failed check is written down as a failed
# check and the next one comes five minutes later.
class HetznerAvailabilityCheckJob < ApplicationJob

  queue_as :default

  def perform
    at = Time.current
    availability = HetznerCloudClient.from_credentials.server_type_availability
    HetznerAvailabilitySample.record!(availability, at:)
  rescue HetznerCloudClient::Error => e
    HetznerAvailabilitySample.record_failure!(e.code.presence || e.class.name.demodulize, at:)
  end

end
