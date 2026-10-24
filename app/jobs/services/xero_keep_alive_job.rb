# Xero refresh tokens die after 60 days unused, and the house only refreshes
# when a resident asks for a token. Once a day, refresh any connected Xero
# connection that hasn't refreshed for 30 days, so an idle connection stays
# alive. A dead grant marks the connection "reauthorizing" (Reconnect needed);
# a network or provider error leaves it alone for tomorrow's run.
class Services::XeroKeepAliveJob < ApplicationJob

  queue_as :default

  def perform
    adapter = Services::Definition.fetch("xero").adapter
    ServiceConnection.where(provider: "xero", status: "connected").find_each do |connection|
      adapter.keep_alive!(connection)
    rescue Services::AdapterError => e
      Rails.logger.warn("Xero keep-alive for service connection #{connection.id} failed: #{e.class}")
    end
  end

end
