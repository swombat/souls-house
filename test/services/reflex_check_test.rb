require "test_helper"

class ReflexCheckTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @chat = @agent.account.chats.create!(title: "Reflexes", manual_responses: true, agents: [ @agent, @other ])
    switches(scope: "all", account: true)
    @live = reflex("Live", live: true)
    @shadow = reflex("Shadow")
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
    assert_equal [ @live.to_param, @shadow.to_param ].sort, questions.keys.sort
    assert_equal "noul", questions[@live.to_param][:type]
    assert_includes questions[@live.to_param][:instructions], "Question: #{@live.shape}"
    assert_includes questions[@live.to_param][:instructions], ReflexCheck::INSTRUCTIONS
    assert_equal UtilityInference::REQUEST_TIMEOUT, calls.first[:timeout]
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

  test "judgments are written for every reflex, shadow ones too; only live ones at or above threshold are offered" do
    exact = reflex("Exact", live: true)
    low = reflex("Low", live: true)
    message = say("Post")
    scores = { @live.to_param => 0.9, @shadow.to_param => 0.99, exact.to_param => ReflexCheck::THRESHOLD, low.to_param => 0.74 }
    cues = UtilityInference.stub(:decide, ->(**) { scores }) { ReflexCheck.new(message).call }

    assert_equal [ @live.to_param, exact.to_param ].sort, cues.map(&:id).sort
    cue = cues.find { |c| c.id == @live.to_param }
    assert_equal({ id: @live.to_param, name: "Live", reminder: "Reminder for Live" }, cue.as_json)

    judgments = Reflex::Judgment.where(message: message).index_by(&:reflex_id)
    assert_equal 4, judgments.size
    assert_in_delta 0.99, judgments[@shadow.id].score
    assert_not judgments[@shadow.id].offered
    assert judgments[@live.id].offered
    assert judgments[exact.id].offered
    assert_not judgments[low.id].offered
    assert_in_delta 0.74, judgments[low.id].score
  end

  test "under the threshold there is no cue" do
    message = say("Post")
    cues = UtilityInference.stub(:decide, ->(questions:, **) { questions.keys.index_with(0.5) }) { ReflexCheck.new(message).call }
    assert_empty cues
    assert_equal 2, Reflex::Judgment.where(message: message, offered: false).count
  end

  test "a classifier failure answers no cues and records unscored rows" do
    message = say("Post")
    cues = UtilityInference.stub(:decide, ->(**) { raise UtilityInference::InvalidResponse, "bad" }) { ReflexCheck.new(message).call }
    assert_empty cues
    rows = Reflex::Judgment.where(message: message)
    assert_equal 2, rows.count
    assert rows.all? { |r| r.score.nil? && !r.offered }
  end

  test "with raise_errors a classifier failure propagates and records nothing" do
    message = say("Post")
    UtilityInference.stub(:decide, ->(**) { raise UtilityInference::InvalidResponse, "bad" }) do
      assert_raises(UtilityInference::InvalidResponse) { ReflexCheck.new(message).call(raise_errors: true) }
    end
    assert_equal 0, Reflex::Judgment.where(message: message).count
  end

  test "after_post enqueues the job and returns no cues while no reflex is live" do
    @live.update!(live: false)
    message = say("Post")
    UtilityInference.stub :decide, ->(**) { flunk "the shadow path runs in the job" } do
      assert_enqueued_with(job: ReflexCheckJob, args: [ message.id ]) do
        assert_equal [], ReflexCheck.after_post(message)
      end
    end
    assert_equal 0, Reflex::Judgment.count
  end

  test "a discarded live reflex does not make the check synchronous" do
    @live.discard
    message = say("Post")
    assert_enqueued_with(job: ReflexCheckJob, args: [ message.id ]) do
      UtilityInference.stub(:decide, ->(**) { flunk "shadow only" }) { ReflexCheck.after_post(message) }
    end
  end

  test "after_post runs synchronously with the live timeout when a reflex is live" do
    message = say("Post")
    seen = nil
    cues = nil
    UtilityInference.stub(:decide, ->(questions:, timeout:, **) {
      seen = timeout
      questions.keys.index_with(0.8)
    }) do
      assert_no_enqueued_jobs(only: ReflexCheckJob) { cues = ReflexCheck.after_post(message) }
    end
    assert_equal ReflexCheck::LIVE_TIMEOUT, seen
    assert_equal [ @live.to_param ], cues.map(&:id)
    assert_equal 2, Reflex::Judgment.where(message: message).count
  end

  test "after_post does nothing without reflexes" do
    @agent.reflexes.each(&:discard)
    message = say("Post")
    assert_no_enqueued_jobs(only: ReflexCheckJob) do
      UtilityInference.stub(:decide, ->(**) { flunk "nothing to judge" }) do
        assert_equal [], ReflexCheck.after_post(message)
      end
    end
  end

  test "after_post ignores posts that are not a resident's" do
    human = @chat.messages.create!(role: "user", user: users(:user_1), content: "Human post")
    progress = @chat.messages.create!(role: "assistant", agent: @agent, content: "Working…", progress_message: true)
    UtilityInference.stub(:decide, ->(**) { flunk "not checkable" }) do
      assert_no_enqueued_jobs(only: ReflexCheckJob) do
        assert_equal [], ReflexCheck.after_post(human)
        assert_equal [], ReflexCheck.after_post(progress)
        assert_equal [], ReflexCheck.after_post(nil)
      end
    end
  end

  test "the site scope and the account switch must both allow the check" do
    message = say("Post")
    blocked = [
      [ "off", true, false ], [ "off", true, true ],
      [ "selected", true, false ],
      [ "all", false, false ], [ "selected", false, true ]
    ]
    allowed = [ [ "all", true, false ], [ "selected", true, true ] ]

    UtilityInference.stub :decide, ->(questions:, **) { questions.keys.index_with(0.9) } do
      blocked.each do |scope, account, chosen|
        switches(scope: scope, account: account, chosen: chosen)
        assert_not ReflexCheck.enabled_for?(@agent), [ scope, account, chosen ].inspect
        assert_equal [], ReflexCheck.after_post(message.reload), [ scope, account, chosen ].inspect
      end
      assert_equal 0, Reflex::Judgment.count

      allowed.each do |scope, account, chosen|
        switches(scope: scope, account: account, chosen: chosen)
        assert ReflexCheck.enabled_for?(@agent), [ scope, account, chosen ].inspect
        assert_equal [ @live.to_param ], ReflexCheck.after_post(message.reload).map(&:id), [ scope, account, chosen ].inspect
      end
    end
  end

  test "selected scope only checks the chosen resident" do
    switches(scope: "selected", account: true, chosen: false)
    Agent.where(id: @other.id).update_all(reflexes_chosen: true)
    assert_not ReflexCheck.enabled_for?(@agent)
    assert ReflexCheck.enabled_for?(@other.reload)
  end

  test "any unexpected error in after_post answers no cues" do
    message = say("Post")
    assert_equal [], UtilityInference.stub(:decide, ->(**) { raise "boom" }) { ReflexCheck.after_post(message) }
    assert_equal [], UtilityInference.stub(:decide, ->(**) { raise ActiveRecord::StatementInvalid, "db" }) { ReflexCheck.after_post(message) }
    UtilityInference.stub(:decide, ->(questions:, **) { questions.keys.index_with(0.9) }) do
      Reflex::Judgment.stub(:upsert_all, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
        assert_equal [], ReflexCheck.after_post(message)
      end
    end
    # A malformed answer missing a key is also contained.
    assert_equal [], UtilityInference.stub(:decide, ->(**) { {} }) { ReflexCheck.after_post(message) }
  end

  test "a recorded score is not overwritten by a later failure" do
    message = say("Post")
    UtilityInference.stub(:decide, ->(questions:, **) { questions.keys.index_with(0.9) }) { ReflexCheck.new(message).call }
    ReflexCheck.new(message).record_failure
    assert_in_delta 0.9, Reflex::Judgment.find_by!(reflex: @live, message: message).score
    assert Reflex::Judgment.find_by!(reflex: @live, message: message).offered
  end

  private

  def say(content)
    @chat.messages.create!(role: "assistant", agent: @agent, content: content)
  end

  def reflex(name, live: false)
    @agent.reflexes.create!(name: name, shape: "Does the post match #{name}?", reminder: "Reminder for #{name}", live: live)
  end

  def switches(scope:, account:, chosen: false)
    Setting.instance.update!(reflexes_scope: scope)
    @agent.account.update!(reflexes_enabled: account)
    Agent.where(id: @agent.id).update_all(reflexes_chosen: chosen)
    @agent.reload
  end

end
