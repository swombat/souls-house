# Did this run have the Chaos hooks its resident expects, and did they fire?
# (jaMBVj, from jpzvnY.) On 12 Nov 2026 a storage move dropped Lume's hook
# rows and Lume woke without the wake hook for 14 hours; from the inside it
# felt whole, and nothing in the house noticed. The one it happens to can't
# see it, so the house checks every run.
#
# The shim reports, per run, the hooks `chaos hooks list` showed for the
# workspace (id, event, enabled, approved, inactive_reason) and, when the Chaos
# build emits hook events, which hooks completed and how. Never a command or
# its output.
#
# A hook that is absent isn't automatically broken (Mira). Each resident has
# an explicit expectation per event: set "expected" the first time a run sees
# a working hook for it (source "observed"), or by the owner or the resident;
# set "off" when a removal was on purpose, which stops the warning. Each
# expected hook is held against its own trigger: session_start on a fresh
# Chaos session only, before_turn on every turn, stop when the turn finished.
class HookPresence

  EVENTS = %w[session_start before_turn stop].freeze
  STATES = %w[expected off].freeze
  SOURCES = %w[observed owner resident].freeze
  LABELS = { "session_start" => "wake (session_start)", "before_turn" => "before_turn", "stop" => "stop" }.freeze
  FRESH_OUTCOMES = %w[fresh legacy_fresh rolled fresh_fallback].freeze

  attr_reader :interaction, :report

  def self.evaluate!(interaction)
    new(interaction).evaluate!
  end

  def initialize(interaction)
    @interaction = interaction
    report = interaction.response_body.is_a?(Hash) ? interaction.response_body.dig("telemetry", "hooks") : nil
    @report = report.is_a?(Hash) ? report : nil
  end

  # Records newly observed expectations, then stores and returns the warning
  # (nil when every expectation was met or nothing was reported).
  def evaluate!
    return nil unless report && interaction.agent

    observe!
    warning = warning_text
    interaction.update_column(:hook_warning, warning) if interaction.hook_warning != warning
    warning
  end

  def warning_text
    problems = expected_events.filter_map { |event| problem_for(event) }
    return nil if problems.empty?

    "Chaos hooks: #{problems.join('; ')}."
  end

  def expected_events
    expectations = interaction.agent.hook_expectations || {}
    EVENTS.select { |event| expectations.dig(event, "state") == "expected" }
  end

  def problem_for(event)
    label = LABELS.fetch(event)
    unless report["status"] == "ok"
      reason = report["reason"].presence || "unknown reason"
      return "couldn't check the #{label} hook (#{reason})"
    end

    hooks = Array(report["hooks"]).select { |hook| hook.is_a?(Hash) && hook["event"] == event }
    return "no #{label} hook is configured" if hooks.empty?
    return "the #{label} hook is disabled" if hooks.none? { |hook| hook["enabled"] }
    return "the #{label} hook is not approved" if hooks.none? { |hook| hook["enabled"] && hook["approved"] }

    live = hooks.select { |hook| working?(hook) }
    if live.empty?
      reason = hooks.filter_map { |hook| hook["inactive_reason"].presence }.first
      return "the #{label} hook is inactive (#{reason})"
    end

    firing_problem(event, label, live)
  end

  def working?(hook)
    hook["enabled"] && hook["approved"] && hook["inactive_reason"].blank?
  end

  private

  # Only judged when the Chaos build reports hook runs at all; until then
  # "fired" is unknown, never assumed either way.
  def firing_problem(event, label, live)
    return nil unless report["runs_reported"] && triggered?(event)

    ids = live.map { |hook| hook["id"] }
    runs = Array(report["runs"]).select { |run| run.is_a?(Hash) && run["event"] == event }
    runs = runs.select { |run| run["id"].blank? || ids.include?(run["id"]) }
    return "the #{label} hook didn't fire" if runs.empty?
    return nil if runs.any? { |run| run["status"] == "completed" }

    "the #{label} hook #{runs.map { |run| run['status'] }.uniq.join(' / ')}"
  end

  def triggered?(event)
    case event
    when "session_start" then interaction.session_outcome.in?(FRESH_OUTCOMES)
    when "before_turn" then true
    when "stop" then interaction.runtime_status == "ok" && interaction.runtime_returncode.to_i.zero?
    end
  end

  def observe!
    return unless report["status"] == "ok"

    seen = Array(report["hooks"]).select { |hook| hook.is_a?(Hash) && working?(hook) }.map { |hook| hook["event"] }
    return if seen.empty?

    agent = interaction.agent
    agent.with_lock do
      expectations = (agent.hook_expectations || {}).deep_dup
      added = (seen & EVENTS).reject { |event| expectations.key?(event) }
      next if added.empty?

      added.each do |event|
        expectations[event] = { "state" => "expected", "source" => "observed", "at" => Time.current.iso8601 }
      end
      agent.update_column(:hook_expectations, expectations)
    end
  end

end
