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

  Verdict = Struct.new(:wake, :person_holds, keyword_init: true) do
    # Residents scored over the threshold, highest first.
    def wake_names(threshold = WAKE_THRESHOLD)
      wake.select { |_, score| score >= threshold }.sort_by { |_, score| -score }.map(&:first)
    end

    def person_holds?(threshold = PERSON_HOLDS_THRESHOLD)
      person_holds >= threshold
    end
  end

  def self.question_key(name)
    "can_act:#{name.to_s.parameterize}"
  end

  def self.questions(resident_names)
    questions = resident_names.index_with do |name|
      { type: "noul", instructions: PromptTemplate.render("stalled_thread_sweep", :resident_can_act, resident: name).squish }
    end.transform_keys { |name| question_key(name) }
    questions[PERSON_HOLDS] = { type: "noul", instructions: PromptTemplate.render("stalled_thread_sweep", :person_holds).squish }
    questions
  end

  # state: StalledThreadSnapshot#state (or a stored copy of one).
  # decide: the inference call, swappable for recorded answers in tests.
  def self.call(state, decide: UtilityInference.method(:decide))
    names = Array(state[:residents_in_room] || state["residents_in_room"]).map { |r| r[:name] || r["name"] }
    answers = decide.call(state: state, questions: questions(names))
    Verdict.new(
      wake: names.index_with { |name| answers.fetch(question_key(name)) },
      person_holds: answers.fetch(PERSON_HOLDS)
    )
  end

end
