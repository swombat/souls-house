require "zlib"

# The whimsical face of a run on its activity card (eKmBwJ, planned with
# Daniel in jZWdzJ). Three stages get a creature and a phrase; every other
# state keeps its plain status_label and gets neither. Choices are seeded from
# the run id, so a refresh lands on the same creature and phrase, and a phrase
# never changes within a stage. status_label is untouched: the avatars, the
# room spinner and everything else that reads it keep their plain words.
module AgentRuntimeInteraction::StatusPresence

  FAMILIES = %w[rabbit flame wisp bird cat seed drop jelly bat lantern ripple roof].freeze

  # The last phrase in each list is the rare silly one, about one in ten.
  PHRASES = {
    "arriving" => [
      "is reading their own handwriting", "is coming into earshot", "is tuning in",
      "is arriving across the wire", "is settling into a body", "is gathering a voice",
      "is letting their eyes adjust", "is catching the thread", "is pulling up a chair",
      "is checking their pockets for yesterday"
    ],
    "here" => [
      "is keeping company", "is in the room", "is sitting with the question",
      "is turning the idea in the light", "is leaning in", "is trying the words aloud",
      "is following where this goes", "is looking closely", "has both hands round the cup",
      "is arguing with their own first thought"
    ],
    "settled" => [
      "stepped back to listen", "pushed the chair back in", "let the chord ring out",
      "closed the notebook", "handed the thread back", "left the light on low",
      "set the pen down", "put a ribbon in the book", "is resting between turns",
      "said their piece"
    ]
  }.transform_values(&:freeze).freeze

  # What a screen reader hears once per stage change: the plain words.
  PLAIN = { "arriving" => "is waking up", "here" => "is working", "settled" => "finished" }.freeze

  RARE_IN = 10

  module_function

  # The stage, or nil when the plain words must stand alone: queued, errors,
  # time-outs, cancellations, lost contact, out of memory, an unconfirmed exit,
  # or live updates gone stale (an animated creature would claim it is alive).
  def stage_for(state:, waking:, health:, exit_unconfirmed:, out_of_memory:, fallback:)
    return if exit_unconfirmed || out_of_memory || fallback

    case state
    when "preparing" then "arriving" unless health == "stale"
    when "running"
      return if health == "stale"
      return "arriving" if waking || health == "connecting"

      "here"
    when "completed" then "settled"
    end
  end

  def presentation(run_id:, stage:, replied:)
    return { status_stage: nil, status_creature: nil, status_phrase: nil, status_plain: nil } if stage.nil? || run_id.blank?

    {
      status_stage: stage,
      status_creature: FAMILIES[seed(run_id, "family") % FAMILIES.size],
      status_phrase: phrase(run_id, stage, replied:),
      status_plain: PLAIN.fetch(stage)
    }
  end

  # "Said their piece" only when the run has a linked reply; a quiet finish
  # gets no guessed reason, so it draws only from the ordinary nine.
  def phrase(run_id, stage, replied: false)
    list = PHRASES.fetch(stage)
    ordinary = list[0...-1]
    roll = seed(run_id, stage)
    rare_allowed = stage != "settled" || replied
    return list.last if rare_allowed && (roll % RARE_IN).zero?

    ordinary[(roll / RARE_IN) % ordinary.size]
  end

  def seed(run_id, salt)
    Zlib.crc32("#{salt}:#{run_id}")
  end

end
