require "test_helper"

class ReflexCheckJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Reflexes", manual_responses: true, agents: [ @agent ])
    Setting.instance.update!(reflexes_scope: "account_choice")
    @agent.account.update!(reflexes_enabled: true)
    @first = reflex("First")
    @second = reflex("Second")
    @message = @chat.messages.create!(role: "assistant", agent: @agent, content: "I'll post the link later.")
  end

  test "performs the check and records scores, offering nothing while shadow" do
    calls = 0
    UtilityInference.stub :decide, ->(questions:, **) {
      calls += 1
      questions.keys.index_with(0.9)
    } do
      ReflexCheckJob.perform_now(@message.id)
    end
    assert_equal 1, calls
    rows = Reflex::Judgment.where(message: @message)
    assert_equal [ @first.id, @second.id ].sort, rows.map(&:reflex_id).sort
    assert rows.all? { |r| r.score == 0.9 && !r.offered }
  end

  test "a reflex switched live after the post is judged but never offered by the job" do
    @first.update!(live: true)
    result = nil
    UtilityInference.stub :decide, ->(questions:, **) { questions.keys.index_with(0.95) } do
      result = ReflexCheckJob.new(@message.id).perform(@message.id)
    end
    assert_equal [], Array(result)
    rows = Reflex::Judgment.where(message: @message)
    assert_equal 2, rows.count
    assert rows.all? { |r| r.score == 0.95 && !r.offered }
  end

  test "a retry after the reflex went live still offers nothing" do
    attempts = 0
    UtilityInference.stub :decide, ->(questions:, **) {
      attempts += 1
      raise UtilityInference::InvalidResponse, "bad" if attempts == 1
      questions.keys.index_with(0.95)
    } do
      assert_raises(UtilityInference::InvalidResponse) { ReflexCheckJob.new(@message.id).perform(@message.id) }
      @first.update!(live: true)
      ReflexCheckJob.new(@message.id).perform(@message.id)
    end
    assert_equal 2, attempts
    assert Reflex::Judgment.where(message: @message).all? { |r| r.score == 0.95 && !r.offered }
  end

  test "an invalid response is retried and records nothing until the attempts run out" do
    UtilityInference.stub :decide, ->(**) { raise UtilityInference::InvalidResponse, "bad" } do
      assert_enqueued_with(job: ReflexCheckJob, args: [ @message.id ]) do
        ReflexCheckJob.perform_now(@message.id)
      end
    end
    assert_equal 0, Reflex::Judgment.count
  end

  test "when the retries are exhausted the judgments are recorded unscored" do
    calls = 0
    UtilityInference.stub :decide, ->(**) {
      calls += 1
      raise UtilityInference::InvalidResponse, "bad"
    } do
      perform_enqueued_jobs(only: ReflexCheckJob) { ReflexCheckJob.perform_later(@message.id) }
    end
    assert_equal ReflexCheckJob::ATTEMPTS, calls
    rows = Reflex::Judgment.where(message: @message)
    assert_equal 2, rows.count
    assert rows.all? { |r| r.score.nil? && !r.offered }
  end

  test "missing credentials discard the job with unscored rows" do
    UtilityInference.stub :decide, ->(**) { raise UtilityInference::MissingCredentials, "none" } do
      assert_no_enqueued_jobs(only: ReflexCheckJob) { ReflexCheckJob.perform_now(@message.id) }
    end
    rows = Reflex::Judgment.where(message: @message)
    assert_equal 2, rows.count
    assert rows.all? { |r| r.score.nil? }
  end

  test "a later success fills the scores in over unscored rows" do
    ReflexCheck.new(@message).record_failure
    assert_equal 2, Reflex::Judgment.where(message: @message, score: nil).count
    UtilityInference.stub :decide, ->(questions:, **) { questions.keys.index_with(0.4) } do
      ReflexCheckJob.perform_now(@message.id)
    end
    rows = Reflex::Judgment.where(message: @message)
    assert_equal 2, rows.count
    assert rows.all? { |r| r.score == 0.4 }
  end

  test "a post already scored for every reflex is skipped" do
    [ @first, @second ].each { |r| r.judgments.create!(message: @message, score: 0.2) }
    UtilityInference.stub :decide, ->(**) { flunk "already judged" } do
      assert_no_difference(-> { Reflex::Judgment.where(score: nil).count }) { ReflexCheckJob.perform_now(@message.id) }
    end
    assert_equal [ 0.2, 0.2 ], Reflex::Judgment.where(message: @message).pluck(:score)
  end

  test "a post partly scored is judged again" do
    @first.judgments.create!(message: @message, score: 0.2)
    calls = 0
    UtilityInference.stub :decide, ->(questions:, **) { calls += 1; questions.keys.index_with(0.3) } do
      ReflexCheckJob.perform_now(@message.id)
    end
    assert_equal 1, calls
    assert_equal [ 0.3, 0.3 ], Reflex::Judgment.where(message: @message).order(:reflex_id).pluck(:score)
  end

  test "reflexes written after the message are not asked" do
    later = travel(1.minute) { reflex("Later") }
    seen = nil
    UtilityInference.stub :decide, ->(questions:, **) { seen = questions.keys; questions.keys.index_with(0.5) } do
      ReflexCheckJob.perform_now(@message.id)
    end
    assert_equal [ @first.to_param, @second.to_param ].sort, seen.sort
    assert_not Reflex::Judgment.exists?(reflex: later)
  end

  test "nothing happens for a missing message or when switched off" do
    UtilityInference.stub :decide, ->(**) { flunk "not checkable" } do
      ReflexCheckJob.perform_now(0)
      @agent.account.update!(reflexes_enabled: false)
      ReflexCheckJob.perform_now(@message.id)
    end
    assert_equal 0, Reflex::Judgment.count
  end

  private

  def reflex(name)
    @agent.reflexes.create!(name: name, shape: "Does the post match #{name}?", reminder: "Reminder for #{name}")
  end

end
