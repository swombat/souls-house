# Tells the person who connected a service that its sign-in is about to end,
# or has ended, when the house cannot renew it (LinkedIn's 60-day member
# sign-in). Sent by LinkedinGrantExpiryJob, once per grant per notice.
class ServiceConnectionMailer < ApplicationMailer

  def grant_expiring(connection, expires_at)
    load(connection, expires_at)
    mail(to: @user.email_address, subject: "Your #{@service} connection ends on #{@ends_on}")
  end

  def grant_ended(connection, expires_at)
    load(connection, expires_at)
    mail(to: @user.email_address, subject: "Your #{@service} connection has ended")
  end

  private

  def load(connection, expires_at)
    @connection = connection
    @user = connection.connected_by_user
    @service = connection.definition.name
    @identity = connection.display_label
    zone = ActiveSupport::TimeZone[@user.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    @ends_on = expires_at.in_time_zone(zone).strftime("%-d %B %Y")
    @integrations_url = account_integrations_url(connection.account)
  end

end
