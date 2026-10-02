# A bounded projection of direct-child lifecycle observations, not a process
# registry. Kernel identifiers are hashed for ingestion and never presented.
class RuntimeSubagents

  LIMIT = 32
  IDENTITY_LIMIT = 1_024
  STATUSES = %w[pending_init running interrupted completed errored shutdown not_found unknown].freeze
  ACTIVE = %w[pending_init running].freeze
  KEY = "_subagents"

  attr_reader :state

  def initialize(source = nil)
    @state = source.is_a?(Hash) ? source.deep_dup : {}
    @state["identities"] = Array(@state["identities"]).first(IDENTITY_LIMIT)
    @state["children"] = Array(@state["children"]).first(LIMIT).filter_map { |child| self.class.public_child(child) }
    @state["capped"] = @state["capped"] == true
  end

  def self.ingress(data, heartbeat: false)
    return unless data.is_a?(Hash) && (heartbeat ? STATUSES : STATUSES - [ "unknown" ]).include?(data["status"])
    return unless %w[parent_process_id child_process_id].all? do |key|
      data[key].is_a?(String) && data[key].bytesize.between?(1, 200) && data[key].match?(/\A[[:graph:]]+\z/)
    end
    return unless %w[agent_nickname model].all? { |key| data[key].nil? || (data[key].is_a?(String) && data[key].bytesize <= 200) }

    data.slice("child_process_id", "agent_nickname", "model", "status")
  end

  def self.public_child(data)
    return unless data.is_a?(Hash) && data["ordinal"].is_a?(Integer) && data["ordinal"].between?(1, LIMIT)
    return unless STATUSES.include?(data["status"])
    return unless %w[nickname model].all? { |key| data[key].nil? || (data[key].is_a?(String) && data[key].bytesize <= 200) }

    { "ordinal" => data["ordinal"], "nickname" => clean(data["nickname"]),
      "model" => clean(data["model"]), "status" => data["status"] }
  end

  def self.clean(value)
    value&.gsub(/[\x00-\x1f\x7f]/, "")
  end

  def observe(data, run_id:, heartbeat: false)
    digest = Digest::SHA256.hexdigest("#{run_id}:#{data.fetch('child_process_id')}")
    index = state["identities"].index(digest)
    unless index
      if state["identities"].size >= IDENTITY_LIMIT
        state["capped"] = true
        return {}
      end
      index = state["identities"].size
      state["identities"] << digest
    end
    return {} if index >= LIMIT

    ordinal = index + 1
    previous = state["children"].find { |child| child["ordinal"] == ordinal }
    # A cached heartbeat cannot prove that a transition occurred after a gap.
    # Only a fresh, explicit lifecycle event may replace an existing status.
    status = heartbeat ? previous&.fetch("status", nil) || "unknown" : data["status"]
    child = {
      "ordinal" => ordinal, "status" => status,
      "nickname" => data.key?("agent_nickname") ? self.class.clean(data["agent_nickname"]) : previous&.fetch("nickname", nil),
      "model" => data.key?("model") ? self.class.clean(data["model"]) : previous&.fetch("model", nil)
    }
    state["children"].reject! { |entry| entry["ordinal"] == ordinal }
    state["children"] << child
    state["children"].sort_by! { |entry| entry["ordinal"] }
    child
  end

  def gap!
    state["children"].each { |child| child["status"] = "unknown" if ACTIVE.include?(child["status"]) }
  end

  def public_snapshot
    {
      "subagents" => state["children"].map(&:dup),
      "subagents_overflow" => [ state["identities"].size - LIMIT, 0 ].max,
      "subagents_overflow_capped" => state["capped"]
    }
  end

end
