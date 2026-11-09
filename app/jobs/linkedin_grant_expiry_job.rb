# LinkedIn member sign-ins last 60 days and cannot be renewed by the house
# (Services::LinkedinAdapter). Once a day: email whoever connected it a week
# before the end, and again when it has ended (marking the connection
# reauthorizing, so its card says Reconnect). Each notice is sent once per
# grant: the latch is the grant's end time, kept in connector_state, so a
# reconnect (a new end time) arms both notices again.
class LinkedinGrantExpiryJob < ApplicationJob

  queue_as :default

  WARN_BEFORE = 7.days

  def perform(now: Time.current)
    ServiceConnection.where(provider: "linkedin", status: %w[connected reauthorizing]).find_each do |connection|
      notify(connection, now)
    rescue StandardError => e
      Rails.logger.error("LinkedinGrantExpiryJob: connection #{connection.id}: #{e.class}: #{e.message}")
    end
  end

  private

  def notify(connection, now)
    expires_at = connection.grant_expires_at
    return unless expires_at

    key = expires_at.utc.iso8601
    if expires_at <= now
      latch(connection, "ended_for", key) do
        connection.update!(status: "reauthorizing") if connection.status == "connected"
        ServiceConnectionMailer.grant_ended(connection, expires_at).deliver_later
      end
    elsif expires_at <= now + WARN_BEFORE && connection.status == "connected"
      latch(connection, "warned_for", key) do
        ServiceConnectionMailer.grant_expiring(connection, expires_at).deliver_later
      end
    end
  end

  def latch(connection, name, key)
    connection.with_lock do
      notices = connection.connector_state.to_h.fetch("grant_notices", {})
      next if notices[name] == key

      yield
      connection.update!(connector_state: connection.connector_state.to_h.merge("grant_notices" => notices.merge(name => key)))
    end
  end

end
