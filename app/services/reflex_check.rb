# Judges one resident post against that resident's kept reflexes (#515,
# docs/reflexes.md): one UtilityInference.decide call, one question per
# reflex keyed by reflex id, state = the post and the six messages before it.
# Every reflex asked gets a Reflex::Judgment row, live or not, so a shadow
# week is readable; a failed call leaves rows with no score.
#
# Where it runs: while none of the resident's reflexes is live, off the post
# path in ReflexCheckJob, so shadowing costs a post nothing. Once one is
# live, synchronously after SafeguardConversationPost.save returns true,
# outside any transaction, with a short timeout; the cues ride back in the
# POST /messages response. A classifier failure is never the post's failure.
class ReflexCheck

  THRESHOLD = 0.75
  CONTEXT_BEFORE = 6
  POST_CHARS = 4_000
  CONTEXT_CHARS = 1_000
  # Per socket wait, on the request path only. The job uses decide's default.
  LIVE_TIMEOUT = 5
  INSTRUCTIONS = PromptTemplate.render("reflex_check", :instructions).squish.freeze

  Cue = Data.define(:id, :name, :reminder) do
    def as_json(*) = { id: id, name: name, reminder: reminder }
  end

  def self.enabled_for?(agent)
    Setting.instance.reflexes_enabled_for?(agent)
  end

  def self.checkable?(message)
    message&.persisted? && message.role == "assistant" && message.agent && message.user_id.nil? &&
      !message.progress_message? && message.content.present? && enabled_for?(message.agent)
  end

  # Called once a resident's post has saved. Returns the cues to offer now
  # (possibly none); never raises for the classifier.
  def self.after_post(message)
    return [] unless checkable?(message)
    reflexes = message.agent.reflexes.kept.to_a
    return [] if reflexes.empty?
    unless reflexes.any?(&:live?)
      ReflexCheckJob.perform_later(message.id)
      return []
    end

    new(message, reflexes).call(timeout: LIVE_TIMEOUT)
  rescue StandardError => error
    # Isolation: whatever goes wrong here, the post has already been made.
    Rails.logger.warn("[ReflexCheck] after_post failed for message #{message&.id}: #{error.class}")
    []
  end

  attr_reader :message, :reflexes

  def initialize(message, reflexes = nil)
    @message = message
    @reflexes = reflexes || message.agent.reflexes.kept.to_a
  end

  # Judges and records; returns the cues for live reflexes at or above the
  # threshold. With raise_errors, a classifier failure propagates (for the
  # job's retries) after nothing is recorded; without, it is recorded as
  # unscored rows and answers no cues. With offer: false (the job), nothing
  # is offered or marked offered, even if a reflex went live after the post:
  # a cue only exists in the post's own response.
  def call(timeout: UtilityInference::REQUEST_TIMEOUT, raise_errors: false, offer: true)
    return [] if reflexes.empty?

    scores = judge(timeout)
    record(scores, offer: offer)
  rescue UtilityInference::Error => error
    raise if raise_errors

    Rails.logger.warn("[ReflexCheck] classifier failed for message #{message.id}: #{error.class}")
    record_failure
    []
  end

  def record_failure
    write(reflexes.map { |reflex| row(reflex, nil, false) })
  end

  def state
    before = message.chat.messages.kept.where(role: %w[user assistant], progress_message: false)
      .where("id < ?", message.id).reorder(id: :desc).limit(CONTEXT_BEFORE).to_a.reverse
    {
      resident: { id: "agent:#{message.agent_id}", name: message.agent.name },
      messages: before.map { |m| describe(m, CONTEXT_CHARS) } + [ describe(message, POST_CHARS).merge(post: true) ]
    }
  end

  private

  def judge(timeout)
    questions = reflexes.to_h { |reflex| [ reflex.to_param, reflex.question ] }
    UtilityInference.decide(state: state, questions: questions, timeout: timeout)
  end

  def record(scores, offer:)
    offered = offer ? reflexes.select { |reflex| reflex.live? && scores.fetch(reflex.to_param) >= THRESHOLD } : []
    write(reflexes.map { |reflex| row(reflex, scores.fetch(reflex.to_param), offered.include?(reflex)) })
    offered.map { |reflex| Cue.new(id: reflex.to_param, name: reflex.name, reminder: reflex.reminder) }
  end

  def row(reflex, score, offered)
    now = Time.current
    { reflex_id: reflex.id, message_id: message.id, score: score, offered: offered, created_at: now, updated_at: now }
  end

  # One row per reflex per post. A retry after a recorded failure fills the
  # score in; a recorded score is never overwritten by a later failure.
  def write(rows)
    if rows.all? { |r| r[:score].nil? }
      Reflex::Judgment.insert_all(rows, unique_by: %i[reflex_id message_id])
    else
      Reflex::Judgment.upsert_all(rows, unique_by: %i[reflex_id message_id], update_only: %i[score offered])
    end
  end

  def describe(m, limit)
    {
      id: m.obfuscated_id,
      author: m.agent&.name || m.user&.full_name || "system",
      at: m.created_at.iso8601,
      content: m.content.to_s.truncate(limit)
    }
  end

end
