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
# expected event is checked hook by hook: a hook seen running before that is
# now gone, off or failing is named by id, and each hook is held against its
# own trigger (session_start and before_turn on every exec, stop when the turn
# finished; a hook with a matcher is never accused of not firing).
class HookPresence

  EVENTS = %w[session_start before_turn stop].freeze
  STATES = %w[expected off].freeze
  SOURCES = %w[observed owner resident].freeze
  LABELS = { "session_start" => "wake (session_start)", "before_turn" => "before_turn", "stop" => "stop" }.freeze
  MAX_KNOWN_IDS = 20

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
    problems = expected_events.flat_map { |event| problems_for(event) }
    return nil if problems.empty?

    "Chaos hooks: #{problems.join('; ')}."
  end

  def expected_events
    EVENTS.select { |event| expectation(event)&.dig("state") == "expected" }
  end

  # Every problem for one expected event, hook by hook (Mira, #959): a healthy
  # neighbouring hook must never mask one that is gone, switched off or failing.
  def problems_for(event)
    label = LABELS.fetch(event)
    unless report["status"] == "ok"
      reason = report["reason"].presence || "unknown reason"
      return [ "couldn't check the #{label} hook (#{reason})" ]
    end

    hooks = hooks_for(event)
    return [ "no #{label} hook is configured" ] if hooks.empty?

    problems = known_ids(event).filter_map { |id| known_hook_problem(label, id, hooks) }
    live = hooks.select { |hook| working?(hook) }
    if live.empty? && problems.empty?
      problems << event_level_problem(label, hooks)
    end
    problems + firing_problems(event, label, live)
  end

  def working?(hook)
    hook["enabled"] && hook["approved"] && hook["inactive_reason"].blank?
  end

  private

  def expectation(event)
    (interaction.agent.hook_expectations || {})[event]
  end

  def known_ids(event)
    Array(expectation(event)&.dig("hook_ids"))
  end

  def hooks_for(event)
    Array(report["hooks"]).select { |hook| hook.is_a?(Hash) && hook["event"] == event }
  end

  # A hook this resident was seen running before.
  def known_hook_problem(label, id, hooks)
    hook = hooks.find { |candidate| candidate["id"] == id }
    return "the #{label} hook #{id} is gone" unless hook
    return "the #{label} hook #{id} is disabled" unless hook["enabled"]
    return "the #{label} hook #{id} is not approved" unless hook["approved"]
    return "the #{label} hook #{id} is inactive (#{hook['inactive_reason']})" if hook["inactive_reason"].present?

    nil
  end

  # Expected (say, by the owner) but none of its hooks works, and none was
  # seen running before.
  def event_level_problem(label, hooks)
    return "the #{label} hook is disabled" if hooks.none? { |hook| hook["enabled"] }
    return "the #{label} hook is not approved" if hooks.none? { |hook| hook["enabled"] && hook["approved"] }

    reason = hooks.filter_map { |hook| hook["inactive_reason"].presence }.first
    "the #{label} hook is inactive (#{reason})"
  end

  # Only judged when the Chaos build reports hook runs at all; until then
  # "fired" is unknown, never assumed either way. A reported failure counts
  # whatever the trigger. "Didn't fire" is only said of an unconditional hook
  # whose trigger happened: a hook with a matcher may rightly not have matched.
  def firing_problems(event, label, live)
    return [] unless report["runs_reported"]

    runs = Array(report["runs"]).select { |run| run.is_a?(Hash) && run["event"] == event }
    live.filter_map do |hook|
      mine = runs.select { |run| run["id"] == hook["id"] }
      if mine.any? { |run| run["status"] == "completed" }
        nil
      elsif mine.any?
        "the #{label} hook #{hook['id']} #{mine.map { |run| run['status'] }.uniq.join(' / ')}"
      elsif triggered?(event) && !hook["has_matcher"]
        "the #{label} hook #{hook['id']} didn't fire"
      end
    end
  end

  # Pinned Chaos dispatches session_start on every exec, with source startup
  # or resume (session/init.rs), so it is due on every run, not only a fresh
  # session (Mira, #959).
  def triggered?(event)
    case event
    when "session_start", "before_turn" then true
    when "stop" then interaction.runtime_status == "ok" && interaction.runtime_returncode.to_i.zero?
    end
  end

  def observe!
    return unless report["status"] == "ok"

    working = Array(report["hooks"]).select { |hook| hook.is_a?(Hash) && EVENTS.include?(hook["event"]) && working?(hook) }
    return if working.empty?

    agent = interaction.agent
    agent.with_lock do
      expectations = (agent.hook_expectations || {}).deep_dup
      changed = false
      working.group_by { |hook| hook["event"] }.each do |event, hooks|
        entry = expectations[event] ||= { "state" => "expected", "source" => "observed", "at" => Time.current.iso8601 }
        ids = Array(entry["hook_ids"])
        merged = (ids | hooks.filter_map { |hook| hook["id"].presence }).first(MAX_KNOWN_IDS)
        next if merged == ids && entry.key?("hook_ids")

        entry["hook_ids"] = merged
        changed = true
      end
      agent.update_column(:hook_expectations, expectations) if changed
    end
  end

end
