# One Jev call over a StalledThreadSnapshot: for each resident in the room,
# the probability that it has an authorised step it could take now, and
# separately the probability that the next move is a person's. Separate
# scores, not one argmax: a room can owe Mira a review and Daniel a question.
#
# Jev answers probabilities only. It cites no messages and gives no reasons,
# so anything downstream that needs an identity for "the same unfinished
# step" has to build it from the room (see the build thread, BjZQAe).
class StalledThreadClassifier

  PERSON_HOLDS = "person_holds".freeze
  WAKE_THRESHOLD = 0.8
  PERSON_HOLDS_THRESHOLD = 0.6

  # wake: [[resident, score], ...] in room order. A list, not a hash keyed by
  # name: two residents may share a name, or names that look alike.
  Verdict = Struct.new(:wake, :person_holds, keyword_init: true) do
    # Residents scored over the threshold, highest first.
    def wake_residents(threshold = WAKE_THRESHOLD)
      wake.select { |_, score| score >= threshold }.sort_by { |_, score| -score }.map(&:first)
    end

    def wake_names(threshold = WAKE_THRESHOLD)
      wake_residents(threshold).map { |resident| resident[:name] || resident["name"] }
    end

    def person_holds?(threshold = PERSON_HOLDS_THRESHOLD)
      person_holds >= threshold
    end
  end

  # Keyed by position in residents_in_room, never by name: names are not
  # unique, and normalising them ("Mira One", "Mira-One") can collide.
  def self.question_key(index)
    "can_act:#{index + 1}"
  end

  def self.questions(resident_names)
    questions = {}
    resident_names.each_with_index do |name, index|
      questions[question_key(index)] = {
        type: "noul", instructions: PromptTemplate.render("stalled_thread_sweep", :resident_can_act, resident: name).squish
      }
    end
    questions[PERSON_HOLDS] = { type: "noul", instructions: PromptTemplate.render("stalled_thread_sweep", :person_holds).squish }
    questions
  end

  # state: StalledThreadSnapshot#state (or a stored copy of one).
  # decide: the inference call, swappable for recorded answers in tests.
  def self.call(state, decide: UtilityInference.method(:decide))
    residents = Array(state[:residents_in_room] || state["residents_in_room"])
    answers = decide.call(state: state, questions: questions(residents.map { |r| r[:name] || r["name"] }))
    Verdict.new(
      wake: residents.each_with_index.map { |resident, index| [ resident, answers.fetch(question_key(index)) ] },
      person_holds: answers.fetch(PERSON_HOLDS)
    )
  end

end
