require "test_helper"

class ReflexCheckTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @chat = @agent.account.chats.create!(title: "Reflexes", manual_responses: true, agents: [ @agent, @other ])
    switches(scope: "account_choice", account: true)
    @first = reflex("First")
    @second = reflex("Second")
  end

  test "one decide call with one question per kept reflex, keyed by reflex id" do
    reflex("Gone").discard
    message = say("I'll post the link tomorrow.")
    calls = []
    UtilityInference.stub :decide, ->(state:, questions:, timeout:) {
      calls << { state: state, questions: questions, timeout: timeout }
      questions.keys.index_with(0.1)
    } do
      ReflexCheck.new(message).call
    end

    assert_equal 1, calls.size
    questions = calls.first[:questions]
    assert_equal [ @first.to_param, @second.to_param ].sort, questions.keys.sort
    assert_equal "noul", questions[@first.to_param][:type]
    assert_includes questions[@first.to_param][:instructions], "Question: #{@first.shape}"
    assert_includes questions[@first.to_param][:instructions], ReflexCheck::INSTRUCTIONS
    assert_equal ReflexCheck::TIMEOUT, calls.first[:timeout]
  end

  test "state is the post last, marked post: true, after at most six earlier messages" do
    earlier = Array.new(8) { |i| @chat.messages.create!(role: i.even? ? "assistant" : "user", agent: i.even? ? @other : nil, user: i.even? ? nil : users(:user_1), content: "Earlier #{i}") }
    @chat.messages.create!(role: "assistant", agent: @other, content: "Progress…", progress_message: true)
    message = say("The post")
    @chat.messages.create!(role: "assistant", agent: @other, content: "After the post")

    state = ReflexCheck.new(message).state
    entries = state[:messages]
    assert_equal ReflexCheck::CONTEXT_BEFORE + 1, entries.size
    assert_equal earlier.last(6).map(&:obfuscated_id), entries.first(6).pluck(:id)
    assert entries.first(6).none? { |e| e.key?(:post) }
    assert_equal({ id: message.obfuscated_id, post: true, content: "The post" }, entries.last.slice(:id, :post, :content))
    assert_equal @agent.name, entries.last[:author]
    assert_equal "agent:#{@agent.id}", state[:resident][:id]
  end

  test "a post with little history has fewer than six before it" do
    @chat.messages.create!(role: "user", user: users(:user_1), content: "Only one before")
    entries = ReflexCheck.new(say("The post")).state[:messages]
    assert_equal 2, entries.size
    assert entries.last[:post]
  end

  test "judgments are written for every reflex; those at or above threshold are offered" do
    exact = reflex("Exact")
    low = reflex("Low")
    message = say("Post")
    scores = { @first.to_param => 0.9, @second.to_param => 0.1, exact.to_param => ReflexCheck::THRESHOLD, low.to_param => 0.74 }
    cues = UtilityInference.stub(:decide, ->(**) { scores }) { ReflexCheck.new(message).call }

    assert_equal [ @first.to_param, exact.to_param ].sort, cues.map(&:id).sort
    cue = cues.find { |c| c.id == @first.to_param }
    assert_equal({ id: @first.to_param, name: "First", reminder: "Reminder for First" }, cue.as_json)

    judgments = Reflex::Judgment.where(message: message).index_by(&:reflex_id)
    assert_equal 4, judgments.size
    assert_in_delta 0.1, judgments[@second.id].score
    assert_not judgments[@second.id].offered
    assert judgments[@first.id].offered
    assert judgments[exact.id].offered
    assert_not judgments[low.id].offered
    assert_in_delta 0.74, judgments[low.id].score
  end

  test "a classifier failure answers no cues and records unscored rows" do
    message = say("Post")
    cues = UtilityInference.stub(:decide, ->(**) { raise UtilityInference::InvalidResponse, "bad" }) { ReflexCheck.new(message).call }
    assert_empty cues
    rows = Reflex::Judgment.where(message: message)
    assert_equal 2, rows.count
    assert rows.all? { |r| r.score.nil? && !r.offered }
  end

  test "a forgotten reflex is not asked" do
    @second.discard
    message = say("Post")
    calls = []
    UtilityInference.stub(:decide, ->(questions:, **) { calls << questions.keys; questions.keys.index_with(0.9) }) do
      assert_equal [ @first.to_param ], ReflexCheck.after_post(message).map(&:id)
    end
    assert_equal [ [ @first.to_param ] ], calls
  end

  test "a held reflex (arrived with an account import) is not asked until a person releases it" do
    @second.update!(held_at: Time.current)
    calls = []
    UtilityInference.stub(:decide, ->(questions:, **) { calls << questions.keys; questions.keys.index_with(0.9) }) do
      ReflexCheck.after_post(say("Done."))
      @first.update!(held_at: Time.current)
      ReflexCheck.after_post(say("Done again."))
      @second.release!
      ReflexCheck.after_post(say("Done a third time."))
    end
    assert_equal [ [ @first.to_param ], [ @second.to_param ] ], calls
  end

  test "after_post runs synchronously with the short timeout" do
    message = say("Post")
    seen = nil
    cues = nil
    UtilityInference.stub(:decide, ->(questions:, timeout:, **) {
      seen = timeout
      questions.keys.index_with(0.8)
    }) do
      cues = ReflexCheck.after_post(message)
    end
    assert_equal ReflexCheck::TIMEOUT, seen
    assert_equal [ @first.to_param, @second.to_param ].sort, cues.map(&:id).sort
    assert_equal 2, Reflex::Judgment.where(message: message).count
  end

  test "after_post does nothing without reflexes" do
    @agent.reflexes.each(&:discard)
    message = say("Post")
    UtilityInference.stub(:decide, ->(**) { flunk "nothing to judge" }) do
      assert_equal [], ReflexCheck.after_post(message)
    end
  end

  test "after_post ignores posts that are not a resident's" do
    human = @chat.messages.create!(role: "user", user: users(:user_1), content: "Human post")
    progress = @chat.messages.create!(role: "assistant", agent: @agent, content: "Working…", progress_message: true)
    UtilityInference.stub(:decide, ->(**) { flunk "not checkable" }) do
      assert_equal [], ReflexCheck.after_post(human)
      assert_equal [], ReflexCheck.after_post(progress)
      assert_equal [], ReflexCheck.after_post(nil)
    end
  end

  test "the site scope decides, and under account_choice the account switch does" do
    message = say("Post")
    blocked = [ [ "disabled", false ], [ "disabled", true ], [ "account_choice", false ] ]
    allowed = [ [ "account_choice", true ], [ "enabled", false ], [ "enabled", true ] ]

    UtilityInference.stub :decide, ->(questions:, **) { questions.keys.index_with(0.9) } do
      blocked.each do |scope, account|
        switches(scope: scope, account: account)
        assert_not ReflexCheck.enabled_for?(@agent), [ scope, account ].inspect
        assert_equal [], ReflexCheck.after_post(message.reload), [ scope, account ].inspect
      end
      assert_equal 0, Reflex::Judgment.count

      allowed.each do |scope, account|
        switches(scope: scope, account: account)
        assert ReflexCheck.enabled_for?(@agent), [ scope, account ].inspect
        assert_equal [ @first.to_param, @second.to_param ].sort, ReflexCheck.after_post(message.reload).map(&:id).sort, [ scope, account ].inspect
      end
    end
  end

  test "an account's own switch survives a site override" do
    switches(scope: "enabled", account: false)
    assert ReflexCheck.enabled_for?(@agent)
    Setting.instance.update!(reflexes_scope: "account_choice")
    assert_not ReflexCheck.enabled_for?(@agent.reload)
    assert_not @agent.account.reload.reflexes_enabled?
  end

  test "the site scope only takes its three states" do
    setting = Setting.instance
    %w[off selected all].each do |old|
      setting.reflexes_scope = old
      assert_not setting.valid?, old
    end
  end

  test "any unexpected error in after_post answers no cues" do
    message = say("Post")
    assert_equal [], UtilityInference.stub(:decide, ->(**) { raise "boom" }) { ReflexCheck.after_post(message) }
    assert_equal [], UtilityInference.stub(:decide, ->(**) { raise ActiveRecord::StatementInvalid, "db" }) { ReflexCheck.after_post(message) }
    UtilityInference.stub(:decide, ->(questions:, **) { questions.keys.index_with(0.9) }) do
      Reflex::Judgment.stub(:insert_all, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
        assert_equal [], ReflexCheck.after_post(message)
      end
    end
    # A malformed answer missing a key is also contained.
    assert_equal [], UtilityInference.stub(:decide, ->(**) { {} }) { ReflexCheck.after_post(message) }
  end

  private

  def say(content)
    @chat.messages.create!(role: "assistant", agent: @agent, content: content)
  end

  def reflex(name)
    @agent.reflexes.create!(name: name, shape: "Does the post match #{name}?", reminder: "Reminder for #{name}")
  end

  def switches(scope:, account:)
    Setting.instance.update!(reflexes_scope: scope)
    @agent.account.update!(reflexes_enabled: account)
    @agent.reload
  end

end
