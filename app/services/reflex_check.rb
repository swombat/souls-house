# Judges one resident post against that resident's kept reflexes (#515,
# docs/reflexes.md): one UtilityInference.decide call, one question per
# reflex keyed by reflex id, state = the post and the six messages before it.
# Every reflex asked gets a Reflex::Judgment row; a failed call leaves rows
# with no score. Every kept reflex is live (#538): there is no shadow.
#
# Where it runs: synchronously after SafeguardConversationPost.save returns
# true, outside any transaction, with a short timeout; the cues ride back in
# the POST /messages response. A classifier failure is never the post's
# failure.
class ReflexCheck

  THRESHOLD = 0.75
  CONTEXT_BEFORE = 6
  POST_CHARS = 4_000
  CONTEXT_CHARS = 1_000
  # Per socket wait: the check runs on the request path.
  TIMEOUT = 5
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
    reflexes = message.agent.reflexes.live.to_a
    return [] if reflexes.empty?

    new(message, reflexes).call
  rescue StandardError => error
    # Isolation: whatever goes wrong here, the post has already been made.
    Rails.logger.warn("[ReflexCheck] after_post failed for message #{message&.id}: #{error.class}")
    []
  end

  attr_reader :message, :reflexes

  def initialize(message, reflexes = nil)
    @message = message
    @reflexes = reflexes || message.agent.reflexes.live.to_a
  end

  # Judges and records; returns the cues for reflexes at or above the
  # threshold. A classifier failure is recorded as unscored rows and answers
  # no cues.
  def call(timeout: TIMEOUT)
    return [] if reflexes.empty?

    record(judge(timeout))
  rescue UtilityInference::Error => error
    Rails.logger.warn("[ReflexCheck] classifier failed for message #{message.id}: #{error.class}")
    write(reflexes.map { |reflex| row(reflex, nil, false) })
    []
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

  def record(scores)
    offered = reflexes.select { |reflex| scores.fetch(reflex.to_param) >= THRESHOLD }
    write(reflexes.map { |reflex| row(reflex, scores.fetch(reflex.to_param), offered.include?(reflex)) })
    offered.map { |reflex| Cue.new(id: reflex.to_param, name: reflex.name, reminder: reflex.reminder) }
  end

  def row(reflex, score, offered)
    now = Time.current
    { reflex_id: reflex.id, message_id: message.id, score: score, offered: offered, created_at: now, updated_at: now }
  end

  # One row per reflex per post.
  def write(rows)
    Reflex::Judgment.insert_all(rows, unique_by: %i[reflex_id message_id])
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
