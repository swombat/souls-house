# Keeps solid_cable's listener thread alive across database errors.
#
# The listener is one thread per web process. It polls solid_cable_messages
# and hands each message to the websockets subscribed to its channel. In
# solid_cable 3.0.12 any exception from that poll ends the thread, and nothing
# starts it again. Open websockets stay connected and keep receiving Action
# Cable's pings (those come from another thread), but no broadcast reaches
# them until the process restarts.
#
# That happened on 20 Nov 2026 at 15:54:52Z when Postgres was restarted: the
# poll raised a connection error, the thread died, and for eleven minutes no
# companion operation, chat stream or other broadcast was delivered.
#
# With this patch the listener reports the error, waits, takes back its
# critical section and polls again. It keeps its last-seen message id, so
# messages written during the outage are still delivered once the database
# answers. Shutdown (Listener::Stop) still ends the thread, including during
# the wait.
require "action_cable/subscription_adapter/solid_cable"

module SolidCableListenerRevival

  RETRY_DELAYS = [ 0.5, 1, 2, 5 ].freeze
  # A failure this long after the previous one starts the delays again.
  RESET_AFTER = 60

  class << self

    attr_writer :retry_delays

    def retry_delays
      @retry_delays || RETRY_DELAYS
    end

    def delay_for(attempt)
      delays = retry_delays
      delays[[ attempt - 1, delays.size - 1 ].min]
    end

  end

  def listen
    attempt = 0
    last_failure_at = nil

    loop do
      begin
        super()
        return
      rescue StandardError => error
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        attempt = 0 if last_failure_at && now - last_failure_at > RESET_AFTER
        last_failure_at = now
        attempt += 1

        report_listener_failure(error, attempt)
        # The original listen's ensure released the critical permit, so
        # shutdown can interrupt this wait with Stop.
        sleep SolidCableListenerRevival.delay_for(attempt)
      end

      # The original listen expects to start holding the critical permit.
      @critical.acquire
    end
  rescue self.class::Stop
    nil
  end

  private
    def report_listener_failure(error, attempt)
      Rails.logger.error(
        "[solid_cable] listener poll failed (attempt #{attempt}), retrying: #{error.class}: #{error.message}"
      )
      Rails.error.report(error, handled: true, severity: :warning,
        context: { component: "solid_cable_listener", attempt: attempt })
    rescue StandardError
      nil
    end

end

ActionCable::SubscriptionAdapter::SolidCable.const_get(:Listener).prepend(SolidCableListenerRevival)
