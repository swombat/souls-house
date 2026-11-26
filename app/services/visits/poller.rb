module Visits
  # Polls a single active Visit for pending wakes on the visited house,
  # deduplicating by [visit_id, remote_wake_id] so redelivered wakes never
  # start a second resident turn at home.
  class Poller

    def initialize(visit, client: Visits::Client.new)
      @visit = visit
      @client = client
    end

    def call
      return { status: :inactive } unless visit.active?
      return { status: :ineligible } unless resident_eligible?
      return { status: :capped } if visit.wake_cap_reached?

      response = client.claim_wakes(visit)

      if response.status == 401
        visit.mark_ended!(status: "revoked", error: "Visit token was rejected by the visited house")
        return { status: :revoked }
      end

      unless response.success?
        visit.record_poll_error!("Visited house answered HTTP #{response.status}")
        return { status: :http_error, http_status: response.status }
      end

      visit.record_poll_success!
      wakes = extract_wakes(response.json)
      enqueued = 0
      deduplicated = 0
      capped = 0

      wakes.each do |raw_wake|
        outcome = process_wake(raw_wake)
        enqueued += 1 if outcome == :enqueued
        deduplicated += 1 if outcome == :deduplicated
        capped += 1 if outcome == :capped
      end

      { status: :ok, enqueued: enqueued, deduplicated: deduplicated, capped: capped }
    rescue Visits::Client::Error => e
      visit.record_poll_error!(e.message)
      { status: :error, error: e.message }
    end

    private

    attr_reader :visit, :client

    def resident_eligible?
      agent = visit.agent
      agent.active? && !agent.paused? && !agent.billing_held? &&
        agent.external? && agent.trigger_bearer_token.present? && !agent.account.disabled?
    end

    def extract_wakes(json)
      list = if json.is_a?(Array)
        json
      elsif json.is_a?(Hash) && json["wakes"].is_a?(Array)
        json["wakes"]
      else
        []
      end
      list.select { |entry| entry.is_a?(Hash) && entry["id"].present? && entry["conversation_id"].present? }
    end

    def process_wake(raw_wake)
      remote_wake_id = raw_wake["id"].to_s
      existing = visit.visit_wakes.find_by(remote_wake_id: remote_wake_id)
      if existing
        return handle_existing_wake(existing)
      end

      return :capped if visit.wake_cap_reached?

      wake = visit.visit_wakes.create!(
        remote_wake_id: remote_wake_id,
        remote_conversation_id: raw_wake["conversation_id"].to_s,
        remote_message_id: raw_wake["message_id"]&.to_s,
        reason: raw_wake["reason"]&.to_s
      )
      visit.update!(last_wake_at: Time.current)
      Visits::TriggerWakeJob.perform_later(wake.id)
      :enqueued
    rescue ActiveRecord::RecordNotUnique
      existing = visit.visit_wakes.find_by(remote_wake_id: remote_wake_id)
      existing ? handle_existing_wake(existing) : :deduplicated
    end

    def handle_existing_wake(wake)
      if !wake.dispatched? && !wake.completed?
        Visits::TriggerWakeJob.perform_later(wake.id)
        return :enqueued
      end

      recomplete_if_finished!(wake)
      :deduplicated
    end

    # If the visited house redelivered a wake whose home turn already finished,
    # confirm completion again so the visited house stops re-leasing it, without
    # ever starting a second home turn.
    def recomplete_if_finished!(wake)
      return unless wake.completed? || wake.agent_runtime_interaction&.finished_at?

      client.complete_wake(visit, wake_id: wake.remote_wake_id)
      wake.mark_completed!
    rescue Visits::Client::Error
      nil
    end

  end
end
