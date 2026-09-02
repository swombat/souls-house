class MeteredActionEvent < ApplicationRecord

  USD_TICKS_PER_DOLLAR = 10_000_000_000
  OUTCOMES = %w[admitted completed upstream_error].freeze
  POLICIES = {
    "x_read" => [
      {
        id: "agent_hour",
        scope: :agent,
        window: 1.hour,
        request_limit: 10,
        spend_cap_ticks: 3_000_000_000
      },
      {
        id: "agent_day",
        scope: :agent,
        window: 24.hours,
        request_limit: 50,
        spend_cap_ticks: 15_000_000_000
      },
      {
        id: "account_day",
        scope: :account,
        window: 24.hours,
        request_limit: 200,
        spend_cap_ticks: 60_000_000_000
      }
    ].freeze
  }.freeze

  Admission = Struct.new(:action, :request_id, :event, :windows, :request_counted, keyword_init: true) do
    def allowed?
      event.present? || blocked_by.empty?
    end

    def blocked_by
      windows.flat_map { |window| window.fetch(:blocked_by) }
    end

    def retry_at
      windows.filter_map { |window| window[:next_slot_at] if window[:blocked_by].any? }.max
    end

    def as_json(*)
      {
        action:,
        request_counted:,
        blocked_by:,
        windows: windows.map { |window| MeteredActionEvent.serialize_window(window) }
      }
    end
  end

  belongs_to :account
  belongs_to :agent

  validates :action, inclusion: { in: POLICIES.keys }
  validates :request_id, presence: true, uniqueness: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :cost_in_usd_ticks, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  attr_readonly :account_id, :agent_id, :action, :request_id

  class << self

    def admit!(action:, agent:, request_id: SecureRandom.uuid, now: Time.current)
      policy = policy_for(action)

      agent.account.with_lock do
        rows_by_window = policy.to_h do |window|
          [ window[:id], rows_for(window, action:, agent:, now:) ]
        end
        windows = policy.map { |window| snapshot(window, rows_by_window.fetch(window[:id])) }
        return Admission.new(action:, request_id:, event: nil, windows:, request_counted: false) if blocked?(windows)

        event = create!(
          account: agent.account,
          agent:,
          action:,
          request_id:,
          outcome: "admitted",
          provider: "xai",
          created_at: now,
          updated_at: now
        )
        windows = policy.map do |window|
          rows = rows_by_window.fetch(window[:id]) + [ [ now, nil ] ]
          snapshot(window, rows)
        end

        Admission.new(action:, request_id:, event:, windows:, request_counted: true)
      end
    end

    def allowance(action:, agent:, request_id: SecureRandom.uuid, request_counted: false, event: nil, now: Time.current)
      policy = policy_for(action)

      agent.account.with_lock do
        admission_for(policy:, action:, agent:, request_id:, request_counted:, event:, now:)
      end
    end

    def serialize_window(window)
      {
        id: window.fetch(:id),
        scope: window.fetch(:scope),
        window_seconds: window.fetch(:window_seconds),
        requests: {
          limit: window.fetch(:request_limit),
          used: window.fetch(:request_count),
          remaining: [ window.fetch(:request_limit) - window.fetch(:request_count), 0 ].max
        },
        spend: {
          cap_usd: usd_from_ticks(window.fetch(:spend_cap_ticks)),
          used_usd: usd_from_ticks(window.fetch(:spend_ticks)),
          remaining_usd: usd_from_ticks([ window.fetch(:spend_cap_ticks) - window.fetch(:spend_ticks), 0 ].max)
        },
        next_slot_at: window[:next_slot_at]&.iso8601
      }
    end

    def usd_from_ticks(ticks)
      (BigDecimal(ticks.to_s) / USD_TICKS_PER_DOLLAR).round(10).to_s("F")
    end

    private

    def policy_for(action)
      POLICIES.fetch(action.to_s) { raise ArgumentError, "Unknown metered action: #{action}" }
    end

    def rows_for(window, action:, agent:, now:)
      relation = where(action:, created_at: (now - window.fetch(:window))..now)
      relation = window[:scope] == :agent ? relation.where(agent:) : relation.where(account: agent.account)
      relation.order(:created_at, :id).pluck(:created_at, :cost_in_usd_ticks)
    end

    def snapshot(window, rows)
      request_count = rows.length
      spend_ticks = rows.sum { |(_, ticks)| ticks.to_i }
      blocked_by = []
      blocked_by << "#{window[:id]}.requests" if request_count >= window.fetch(:request_limit)
      blocked_by << "#{window[:id]}.spend" if spend_ticks >= window.fetch(:spend_cap_ticks)

      window.merge(
        scope: window.fetch(:scope).to_s,
        window_seconds: window.fetch(:window).to_i,
        request_count:,
        spend_ticks:,
        blocked_by:,
        next_slot_at: next_slot_at(window, rows, request_count:, spend_ticks:, blocked: blocked_by.any?)
      )
    end

    def next_slot_at(window, rows, request_count:, spend_ticks:, blocked:)
      return if rows.empty?
      return rows.first.first + window.fetch(:window) unless blocked

      rows.group_by { |(created_at, _)| created_at + window.fetch(:window) }.sort.each do |expires_at, expiring|
        request_count -= expiring.length
        spend_ticks -= expiring.sum { |(_, ticks)| ticks.to_i }
        if request_count < window.fetch(:request_limit) && spend_ticks < window.fetch(:spend_cap_ticks)
          return expires_at
        end
      end

      nil
    end

    def blocked?(windows)
      windows.any? { |window| window[:blocked_by].any? }
    end

    def admission_for(policy:, action:, agent:, request_id:, request_counted:, event:, now:)
      windows = policy.map do |window|
        snapshot(window, rows_for(window, action:, agent:, now:))
      end
      Admission.new(action:, request_id:, event:, windows:, request_counted:)
    end

  end

  def complete!(outcome:, provider_request_id: nil, usage: {}, cost_in_usd_ticks: nil, now: Time.current)
    account.with_lock do
      update!(
        outcome:,
        provider_request_id:,
        usage: usage || {},
        cost_in_usd_ticks:,
        outcome_recorded_at: now
      )

      policy = self.class.send(:policy_for, action)
      self.class.send(
        :admission_for,
        policy:,
        action:,
        agent:,
        request_id:,
        request_counted: true,
        event: self,
        now:
      )
    end
  end

end
