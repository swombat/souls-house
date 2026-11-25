# A rhythm run with one resident already stays off the conversation list
# while nothing in it needs anyone (Chat::QuietRhythmRun). A run with several
# residents shows there, so each day's run would sit on the list unread.
# Daniel's shape (JWdPZY, jWbpGM, elRvNJ): once the run's opening round has
# ended with nobody flagged and no person having spoken, the house asks the
# resident whose turn finished last whether to tidy it away, in whichever way
# this account keeps its list. The house archives nothing by itself.
#
# Openings fan out (one rhythm dispatch reserves every seat at once), so
# nobody knows they finished last until the others have. The question is
# therefore one extra short wake, after the fact (RhythmTidyCheckJob), asked
# once per run whatever the answer: rhythm_occurrences.tidy_asked_at is set in
# the same transaction as the wake's reservation, and the wake's own run
# finishing never asks again.
#
# Only the opening round's runs (the rhythm dispatch's own interactions) can
# be the last finisher: a later peer turn does not inherit the question.
class RhythmTidy

  NOT_A_TURN = %w[cancelled busy].freeze

  attr_reader :occurrence

  def self.for_chat(chat)
    RhythmOccurrence.where(chat_id: chat.id, manual: false).order(:id).first
  end

  def self.for_interaction(interaction)
    return unless interaction&.id

    RhythmOccurrence.find_by(tidy_interaction_id: interaction.id)
  end

  def initialize(occurrence)
    @occurrence = occurrence
  end

  def chat
    occurrence.chat
  end

  def dispatch
    occurrence.message&.message_dispatch
  end

  # Nil when the run may be asked about now; otherwise why not. :busy means
  # "not yet" (something is still running or owed a wake); every other reason
  # means the run is someone's, or can't be asked about at all.
  # except: the tidy wake's own run, when its claim re-checks.
  def refusal_reason(except: nil)
    @except = except
    return :manual if occurrence.manual?
    return :unavailable unless chat.respondable?
    return :single_resident if chat.agents.count < 2
    return :tagged if chat.visual_tag_id?
    return :person_spoke if person_spoke?
    return :flagged if flagged?
    return :busy if busy?
    return :no_opening_round unless dispatch&.rhythm?

    nil
  end

  # The resident whose opening-round turn finished last, if it can still be
  # asked here. Only turns that were claimed and ran count: a reservation
  # that expired unclaimed also gets a finished_at, but was nobody's turn.
  def last_finisher
    run = dispatch.runtime_interactions.where.not(finished_at: nil)
      .where(trigger_kind: "conversation").where.not(dispatch_claimed_at: nil)
      .where.not(execution_state: NOT_A_TURN)
      .reorder(finished_at: :desc, id: :desc).first
    agent = run&.agent
    return unless agent && chat.agents.exists?(agent.id) && agent.eligible_for_conversation?

    agent
  end

  # The ways this resident has to tidy this run; nil if none.
  def ways_for(agent)
    ways = []
    tags = chat.account.visual_tags.hiding_from_list.order(:label).to_a
    if tags.any?
      choices = tags.map { |tag| "#{tag.label.to_json} (#{tag.to_param})" }.join(", ")
      ways << "To mark it done, PATCH /api/v1/conversations/#{chat.to_param} with JSON {\"visual_tag_id\":\"<id>\"} " \
        "using one of this account's tags that hide it from the list: #{choices}."
    end
    # The archive door is home-only (ConversationArchivesController).
    ways << "To archive it, POST /api/v1/conversations/#{chat.to_param}/archive." if chat.account_id == agent.account_id
    return if ways.empty?

    ways.join(" ")
  end

  # What the tidy wake is told. Grants nothing.
  def prompt_text(agent)
    <<~TEXT.strip
      RHYTHM TIDY-UP (platform, not a person). This conversation, #{chat.to_param}, is a run of the rhythm #{occurrence.rhythm_title.to_json}. Its opening round has ended, nobody in it has been flagged, no person has spoken in it, and nothing is still running. Yours was the last turn to finish, so you are the one asked: does it need a person to look at it?

      You may mark it done or archive it, so it doesn't sit on the conversation list, or leave it unchanged. #{ways_for(agent)} Use whichever fits how this account keeps its list. Leave it if something in it should be seen (something made that nobody has read yet, or a question for someone), or if you're unsure. Whatever you choose, say nothing in the room, or at most one line. You won't be asked about this run again, and this wake grants no new permissions.
    TEXT
  end

  private

  # A person's message other than the rhythm's opening (which carries its
  # creator's user). Platform notices have no user and don't count.
  def person_spoke?
    chat.messages.kept.where(role: "user").where.not(user_id: nil).where.not(id: occurrence.message_id).exists?
  end

  def flagged?
    return true if ReplyExpectation.state_open.joins(:message).where(messages: { chat_id: chat.id }).exists?
    return true if Commitment.scheduled.where(source_chat_id: chat.id).exists?

    Commitment.wake_in_custody.where(activation_chat_id: chat.id).exists?
  end

  def busy?
    return true if chat.agent_runtime_interactions.where(finished_at: nil).where.not(id: @except&.id).active.exists?
    return true if MessageDispatch.where(chat_id: chat.id, status: "pending").exists?
    return true if PendingWake.open.where(chat_id: chat.id).exists?

    MessageHandoff.open_requests.where(chat_id: chat.id).exists?
  end

end
