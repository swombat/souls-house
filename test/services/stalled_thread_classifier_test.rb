require "test_helper"

# Plumbing only: what is asked, and how the answers become a verdict. These
# tests replay recorded answers, so they say nothing about how well a changed
# prompt classifies. That is measured offline against labelled real rooms
# (script/stalled_sweeper/README.md) and, for the synthetic fixtures, by the
# live test below when LIVE_JEV is set.
class StalledThreadClassifierTest < ActiveSupport::TestCase

  FIXTURES = Rails.root.join("test/fixtures/files/stalled_sweeper")

  test "one question per resident plus person_holds, each with its own instructions" do
    questions = StalledThreadClassifier.questions([ "Lume", "Mira" ])

    assert_equal [ "can_act:1", "can_act:2", "person_holds" ], questions.keys
    assert_match "Lume", questions["can_act:1"][:instructions]
    assert_no_match "Lume", questions["can_act:2"][:instructions]
    assert questions.values.all? { |q| q[:type] == "noul" }
  end

  test "residents whose names normalise alike keep separate questions and scores" do
    state = { residents_in_room: [ { name: "Mira One" }, { name: "Mira-One" }, { name: "Mîra One" } ] }
    seen = nil
    decide = lambda do |state:, questions:|
      seen = questions
      { "can_act:1" => 0.95, "can_act:2" => 0.1, "can_act:3" => 0.2, "person_holds" => 0.1 }
    end

    verdict = StalledThreadClassifier.call(state, decide: decide)

    assert_equal 4, seen.size
    assert_match "Mira-One", seen["can_act:2"][:instructions]
    assert_equal [ "Mira One" ], verdict.wake_names
    assert_equal [ { name: "Mira One" } ], verdict.wake_residents
  end

  test "recorded answers become a verdict with separate scores" do
    each_fixture do |name, fixture|
      verdict = StalledThreadClassifier.call(fixture["state"].deep_symbolize_keys, decide: recorded(fixture))

      assert_equal fixture["expected"]["wake"], verdict.wake_names, name
      assert_equal fixture["expected"]["person_holds"], verdict.person_holds?, name
    end
  end

  test "a mixed room can owe a resident a step and a person a question at once" do
    fixture = JSON.parse(FIXTURES.join("mixed_merge_owed_and_question.json").read)
    verdict = StalledThreadClassifier.call(fixture["state"].deep_symbolize_keys, decide: recorded(fixture))

    assert_equal [ "Lume" ], verdict.wake_names
    assert verdict.person_holds?
  end

  test "live Jev agrees with the synthetic fixtures" do
    skip "set LIVE_JEV=1 with house OpenRouter credentials to run" unless ENV["LIVE_JEV"] == "1"

    each_fixture do |name, fixture|
      verdict = StalledThreadClassifier.call(fixture["state"].deep_symbolize_keys)
      assert_equal fixture["expected"]["wake"], verdict.wake_names, "#{name}: #{verdict.wake.inspect}"
      assert_equal fixture["expected"]["person_holds"], verdict.person_holds?, "#{name}: #{verdict.person_holds}"
    end
  end

  private

  def each_fixture
    FIXTURES.glob("*.json").sort.each { |path| yield path.basename.to_s, JSON.parse(path.read) }
  end

  def recorded(fixture)
    lambda do |state:, questions:|
      assert_equal fixture["recorded_answers"].keys.sort, questions.keys.sort
      fixture["recorded_answers"]
    end
  end

end
