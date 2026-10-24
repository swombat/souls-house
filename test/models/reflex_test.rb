require "test_helper"

class ReflexTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "requires name, shape and reminder" do
    reflex = @agent.reflexes.build
    assert_not reflex.valid?
    assert reflex.errors.of_kind?(:name, :blank)
    assert reflex.errors.of_kind?(:shape, :blank)
    assert reflex.errors.of_kind?(:reminder, :blank)
  end

  test "length limits" do
    ok = build(name: "n" * Reflex::NAME_LENGTH, shape: "s" * Reflex::SHAPE_LENGTH, reminder: "r" * Reflex::REMINDER_LENGTH)
    assert ok.valid?, ok.errors.full_messages.inspect

    long = build(name: "n" * (Reflex::NAME_LENGTH + 1), shape: "s" * (Reflex::SHAPE_LENGTH + 1), reminder: "r" * (Reflex::REMINDER_LENGTH + 1))
    assert_not long.valid?
    assert long.errors.of_kind?(:name, :too_long)
    assert long.errors.of_kind?(:shape, :too_long)
    assert long.errors.of_kind?(:reminder, :too_long)
  end

  test "a new reflex is not live" do
    assert_not create_reflex.live?
  end

  test "shape is immutable once saved; name, reminder and live can change" do
    reflex = create_reflex
    assert_not reflex.update(shape: "A different question?")
    assert_match "cannot change", reflex.errors[:shape].join
    assert_equal "Does the post promise a follow-up?", reflex.reload.shape

    assert reflex.update(name: "Renamed", reminder: "New line", live: true)
    assert reflex.reload.live?
  end

  test "a resident keeps at most ten reflexes; discarded ones do not count" do
    reflexes = Array.new(Reflex::MAX_KEPT) { |i| create_reflex(name: "R#{i}") }
    extra = build(name: "Eleventh")
    assert_not extra.save
    assert_match "at most #{Reflex::MAX_KEPT}", extra.errors.full_messages.join

    reflexes.first.discard
    assert build(name: "Eleventh").save

    # Another resident's count is their own.
    assert agents(:code_reviewer).reflexes.create(name: "Theirs", shape: "Q?", reminder: "R").persisted?
  end

  test "the limit does not block updates of an existing reflex at the cap" do
    reflexes = Array.new(Reflex::MAX_KEPT) { |i| create_reflex(name: "R#{i}") }
    assert reflexes.last.update(live: true)
  end

  test "live scope is kept and live only" do
    live = create_reflex(name: "Live").tap { |r| r.update!(live: true) }
    create_reflex(name: "Shadow")
    create_reflex(name: "Gone live").tap { |r| r.update!(live: true); r.discard }
    assert_equal [ live ], @agent.reflexes.live.to_a
  end

  test "question carries the shape and json uses obfuscated ids" do
    reflex = create_reflex
    assert_equal "noul", reflex.question[:type]
    assert_includes reflex.question[:instructions], "Question: Does the post promise a follow-up?"
    json = reflex.as_json
    assert_equal reflex.to_param, json[:id]
    assert_not_equal reflex.id, json[:id]
    assert_nil json[:discarded_at]
  end

  test "discarding keeps judgments" do
    reflex = create_reflex
    chat = @agent.account.chats.create!(title: "Reflexes", manual_responses: true, agents: [ @agent ])
    message = chat.messages.create!(role: "assistant", agent: @agent, content: "I'll follow up tomorrow.")
    judgment = reflex.judgments.create!(message: message, score: 0.4)
    reflex.discard
    assert Reflex::Judgment.exists?(judgment.id)
  end

  test "judgment score is between zero and one, or nil" do
    reflex = create_reflex
    chat = @agent.account.chats.create!(title: "Reflexes", manual_responses: true, agents: [ @agent ])
    message = chat.messages.create!(role: "assistant", agent: @agent, content: "Post")
    assert reflex.judgments.build(message: message, score: nil).valid?
    assert reflex.judgments.build(message: message, score: 1).valid?
    assert_not reflex.judgments.build(message: message, score: 1.1).valid?
    assert_not reflex.judgments.build(message: message, score: -0.1).valid?
  end

  private

  def build(name: "Follow-up", shape: "Does the post promise a follow-up?", reminder: "Write the follow-up down.")
    @agent.reflexes.build(name: name, shape: shape, reminder: reminder)
  end

  def create_reflex(**attrs)
    build(**attrs).tap(&:save!)
  end

end
