# "When this happens in that repository, post the result in this
# conversation and wake me once." Armed by a resident (with a grant on the
# repository's GitHub connection) or a person, on a connected
# WatchedRepository.
#
# Lifecycle: armed → fulfilled | expired | cancelled, and fulfilled →
# undeliverable when the room may no longer receive it. Arming persists the
# watch first and then reconciles against GitHub, so a run that finished
# before the watch existed still fulfils it; reconcile and webhook deliveries
# both go through fulfil!, which is the one idempotent path (see
# RepositoryWatchDeliverJob for the effects).
class RepositoryWatch < ApplicationRecord

  EVENT_KINDS = %w[workflow_run deployment_status].freeze
  STATES = %w[armed fulfilled expired undeliverable cancelled].freeze
  RECONCILE_STATUSES = %w[pending done error].freeze
  TERMINAL_DEPLOYMENT_STATES = %w[success failure error].freeze
  WORKFLOW_CONCLUSIONS = %w[success failure neutral cancelled skipped timed_out action_required stale startup_failure].freeze
  DEFAULT_LIFETIME = 24.hours
  MAX_LIFETIME = 7.days
  MIN_LIFETIME = 5.minutes
  FULL_SHA = /\A[0-9a-f]{40}\z/
  SHORT_SHA = /\A[0-9a-f]{7,39}\z/

  belongs_to :account
  belongs_to :watched_repository
  belongs_to :chat
  belongs_to :created_by_agent, class_name: "Agent", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :repository_watch_deliveries, dependent: :delete_all

  validates :event_kind, inclusion: { in: EVENT_KINDS }
  validates :state, inclusion: { in: STATES }
  validates :reconcile_status, inclusion: { in: RECONCILE_STATUSES }
  validates :expires_at, presence: true
  validate :one_creator, on: :create
  validate :filter_shape
  validate :wake_rule, on: :create

  scope :armed, -> { where(state: "armed") }

  # Raised by arm!; status is the HTTP status the API answers with.
  class Refused < StandardError

    attr_reader :status

    def initialize(message, status: :unprocessable_entity)
      super(message)
      @status = status
    end

  end

  # Validate, persist as armed, then reconcile after the commit. by is the
  # Agent or User arming it.
  def self.arm!(repository:, chat:, by:, event_kind:, filter: {}, wake: false, expires_in: nil)
    agent = by.is_a?(Agent) ? by : nil
    user = by.is_a?(User) ? by : nil
    wake_agent_ids = wake ? [ agent&.id ].compact : []
    raise Refused.new("Only a resident can ask to be woken by a watch") if wake && agent.nil?

    refusal = RepositoryWatches::Authority.arm_refusal(repository: repository, chat: chat, agent: agent, user: user)
    raise Refused.new(refusal.last, status: refusal.first) if refusal

    filter = normalise_filter(event_kind, filter.to_h.stringify_keys)
    filter["head_sha"] = resolve_sha(repository, filter["head_sha"]) if filter["head_sha"]

    watch = create!(
      account: repository.account,
      watched_repository: repository,
      chat: chat,
      created_by_agent: agent,
      created_by_user: user,
      event_kind: event_kind,
      filter: filter,
      wake_agent_ids: wake_agent_ids,
      expires_at: Time.current + lifetime(expires_in)
    )
    watch_id = watch.id
    ActiveRecord.after_all_transactions_commit { RepositoryWatchReconcileJob.perform_later(watch_id) }
    watch
  rescue ActiveRecord::RecordInvalid => error
    raise Refused.new(error.record.errors.full_messages.to_sentence)
  end

  # "24h", "90m", "3d", or seconds; nil for the default. Bounded.
  def self.lifetime(value)
    return DEFAULT_LIFETIME if value.blank?

    seconds = case value.to_s.strip
    when /\A(\d+)\s*m\z/ then Regexp.last_match(1).to_i.minutes
    when /\A(\d+)\s*h\z/ then Regexp.last_match(1).to_i.hours
    when /\A(\d+)\s*d\z/ then Regexp.last_match(1).to_i.days
    when /\A(\d+)\s*s?\z/ then Regexp.last_match(1).to_i.seconds
    else raise Refused.new("expires_in must look like 30m, 24h or 7d")
    end
    raise Refused.new("expires_in must be between 5 minutes and 7 days") unless seconds.between?(MIN_LIFETIME, MAX_LIFETIME)

    seconds
  end

  def self.normalise_filter(event_kind, raw)
    raise Refused.new("event must be workflow_run or deployment_status") unless event_kind.in?(EVENT_KINDS)

    list = ->(value) { Array(value).flat_map { |item| item.to_s.split(",") }.map { |item| item.strip.downcase }.reject(&:blank?).uniq.presence }
    filter = {
      "head_sha" => raw["head_sha"].to_s.strip.downcase.presence,
      "workflow_name" => (raw["workflow_name"].to_s.strip.presence if event_kind == "workflow_run"),
      "environment" => (raw["environment"].to_s.strip.presence if event_kind == "deployment_status"),
      "conclusions" => (list.(raw["conclusions"]) if event_kind == "workflow_run"),
      "states" => (list.(raw["states"]) if event_kind == "deployment_status")
    }.compact
    if event_kind == "workflow_run" && filter["head_sha"].blank?
      raise Refused.new("A workflow watch needs the commit sha")
    end
    if event_kind == "deployment_status" && filter["head_sha"].blank? && filter["environment"].blank?
      raise Refused.new("A deployment watch needs an environment or a commit sha")
    end
    if filter["head_sha"] && !filter["head_sha"].match?(SHORT_SHA) && !filter["head_sha"].match?(FULL_SHA)
      raise Refused.new("sha must be 7 to 40 hexadecimal characters")
    end
    if (unknown = Array(filter["conclusions"]) - WORKFLOW_CONCLUSIONS).any?
      raise Refused.new("Unknown conclusion: #{unknown.join(', ')}")
    end
    if (unknown = Array(filter["states"]) - TERMINAL_DEPLOYMENT_STATES).any?
      raise Refused.new("Deployment watches fire on success, failure or error only (not #{unknown.join(', ')})")
    end
    filter
  end

  # A short sha is accepted only when GitHub resolves it to one commit now.
  def self.resolve_sha(repository, sha)
    return sha if sha.match?(FULL_SHA)

    full = RepositoryWatches::GithubClient.new(repository.service_connection).commit_sha(repository.full_name, sha).to_s.downcase
    raise Refused.new("GitHub resolved #{sha} to something that is not a commit sha") unless full.match?(FULL_SHA) && full.start_with?(sha)

    full
  rescue RepositoryWatches::GithubClient::Error => error
    raise Refused.new("Could not resolve #{sha} to one commit in #{repository.full_name} (#{error.message}); give the full 40-character sha")
  end

  def head_sha
    filter["head_sha"]
  end

  def short_sha
    head_sha&.first(7)
  end

  def armed?
    state == "armed"
  end

  def wake_agents
    Agent.where(id: wake_agent_ids).order(:id)
  end

  # Webhook payload or API object: a workflow run.
  def matches_workflow_run?(run)
    return false unless event_kind == "workflow_run"
    return false unless run["status"] == "completed"
    return false unless run["head_sha"].to_s.downcase == head_sha
    return false if filter["workflow_name"].present? && run["name"] != filter["workflow_name"]
    return false if filter["conclusions"].present? && !filter["conclusions"].include?(run["conclusion"].to_s)

    true
  end

  def matches_deployment_status?(status, deployment)
    return false unless event_kind == "deployment_status"
    state = status["state"].to_s
    return false unless state.in?(TERMINAL_DEPLOYMENT_STATES)
    environment = status["environment"].presence || deployment["environment"]
    return false if filter["environment"].present? && environment != filter["environment"]
    return false if head_sha.present? && deployment["sha"].to_s.downcase != head_sha
    return false if filter["states"].present? && !filter["states"].include?(state)
    return false unless head_sha.present? || reached_since_armed?(status)

    true
  end

  # A watch with a sha accepts any terminal status of that sha, however old.
  # Without one ("the next deploy to production") only a status reached at
  # or after arming counts, on every path (webhook, replay, reconcile): an
  # earlier deploy is not the one being waited for. A status with no
  # readable time does not count.
  def reached_since_armed?(status)
    Time.iso8601(status["created_at"].to_s) >= created_at
  rescue ArgumentError
    false
  end

  def self.workflow_fulfilment(run, source:)
    {
      "source" => source,
      "run_id" => run["id"],
      "run_attempt" => run["run_attempt"],
      "workflow_name" => run["name"],
      "sha" => run["head_sha"],
      "conclusion" => run["conclusion"],
      "html_url" => run["html_url"]
    }
  end

  def self.deployment_fulfilment(status, deployment, source:)
    {
      "source" => source,
      "deployment_id" => deployment["id"],
      "deployment_status_id" => status["id"],
      "sha" => deployment["sha"],
      "environment" => status["environment"].presence || deployment["environment"],
      "state" => status["state"],
      "html_url" => status["target_url"].presence || status["log_url"]
    }
  end

  # The one path to fulfilment, for webhooks and reconcile alike. Returns
  # true if this call fulfilled the watch, false if it was no longer armed.
  def fulfil!(fulfilment)
    fulfilled = with_lock do
      next false unless armed?

      update!(state: "fulfilled", fulfilled_at: Time.current, fulfilment: fulfilment,
              reconcile_status: reconcile_status == "pending" ? "done" : reconcile_status)
      repository_watch_deliveries.find_or_create_by!(fulfilment_key: fulfilment_key)
      true
    end
    if fulfilled
      watch_id = id
      ActiveRecord.after_all_transactions_commit { RepositoryWatchDeliverJob.perform_later(watch_id) }
    end
    fulfilled
  end

  # Past its time with nothing seen: say so in the room (no wake).
  def expire!(now: Time.current)
    expired = with_lock do
      next false unless armed? && expires_at <= now

      update!(state: "expired")
      repository_watch_deliveries.find_or_create_by!(fulfilment_key: fulfilment_key)
      true
    end
    if expired
      watch_id = id
      ActiveRecord.after_all_transactions_commit { RepositoryWatchDeliverJob.perform_later(watch_id) }
    end
    expired
  end

  def cancel!(reason: nil)
    with_lock do
      next false unless armed?

      update!(state: "cancelled", cancelled_at: Time.current, cancel_reason: reason)
    end
  end

  def mark_undeliverable!(reason)
    with_lock do
      update!(state: "undeliverable", undeliverable_reason: reason.to_s.truncate(200)) if state == "fulfilled"
    end
  end

  # v1 watches are one-shot, so one fulfilment per watch.
  def fulfilment_key
    id.to_s
  end

  def subject
    if event_kind == "workflow_run"
      filter["workflow_name"].present? ? "#{short_sha} (#{filter['workflow_name']})" : short_sha
    else
      [ filter["environment"], short_sha ].compact.join(" at ")
    end
  end

  # The line posted in the room: the fact, nothing else.
  def delivered_text
    repository = watched_repository.full_name
    case state
    when "expired"
      what = event_kind == "workflow_run" ? "No completion was seen for `#{short_sha}`#{" (#{filter['workflow_name']})" if filter['workflow_name'].present?}" :
        "No finished deployment#{" to #{filter['environment']}" if filter['environment'].present?}#{" for `#{short_sha}`" if short_sha} was seen"
      "#{repository} · #{what} in #{lifetime_label}; the watch has expired."
    else
      data = fulfilment.to_h
      url = safe_url(data["html_url"])
      sha = data["sha"].to_s.first(7)
      line = if event_kind == "workflow_run"
        "#{repository} · #{data['workflow_name']} finished for #{sha}: #{data['conclusion']}"
      else
        "#{repository} · deployment to #{data['environment']}: #{data['state']} for #{sha}"
      end
      [ line, url ].compact.join(" · ")
    end
  end

  def lifetime_label
    seconds = (expires_at - created_at).round
    if seconds >= 2.days.to_i && seconds % 1.day.to_i == 0 then "#{seconds / 1.day.to_i} d"
    elsif seconds % 1.hour.to_i == 0 then "#{seconds / 1.hour.to_i} h"
    else "#{(seconds / 60.0).round} min"
    end
  end

  def status_label
    return "status not established" if armed? && reconcile_status == "error"
    return "delivery failed" if current_delivery&.failed?

    state
  end

  def current_delivery
    repository_watch_deliveries.find { |delivery| delivery.fulfilment_key == fulfilment_key }
  end

  def as_watch_json
    {
      id: to_param,
      repository: watched_repository.full_name,
      repository_id: watched_repository.to_param,
      event: event_kind,
      filter: filter,
      chat_id: chat.to_param,
      wake: wake_agent_ids.any?,
      state: state,
      status: status_label,
      reconcile_status: reconcile_status,
      reconcile_error: reconcile_error,
      expires_at: expires_at.utc.iso8601,
      fulfilled_at: fulfilled_at&.utc&.iso8601,
      fulfilment: fulfilment,
      cancelled_at: cancelled_at&.utc&.iso8601,
      cancel_reason: cancel_reason,
      undeliverable_reason: undeliverable_reason,
      delivery: current_delivery && { status: current_delivery.status, attempts: current_delivery.attempts, last_error: current_delivery.last_error },
      created_by: created_by_agent ? { type: "resident", id: created_by_agent.to_param, name: created_by_agent.name } :
        (created_by_user ? { type: "person", name: created_by_user.full_name.presence || created_by_user.email_address.split("@").first } : nil),
      created_at: created_at.utc.iso8601
    }
  end

  private

  def safe_url(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP) ? value.to_s : nil
  rescue URI::InvalidURIError
    nil
  end

  def one_creator
    errors.add(:base, "A watch is armed by exactly one resident or person") unless [ created_by_agent_id, created_by_user_id ].compact.one?
  end

  def filter_shape
    errors.add(:filter, "needs a full commit sha") if event_kind == "workflow_run" && !head_sha.to_s.match?(FULL_SHA)
    errors.add(:filter, "needs a full commit sha") if head_sha.present? && !head_sha.match?(FULL_SHA)
  end

  # v1: only the arming resident may be woken.
  def wake_rule
    allowed = [ created_by_agent_id ].compact
    errors.add(:wake_agent_ids, "may contain only the arming resident") unless (wake_agent_ids - allowed).empty?
  end

end
