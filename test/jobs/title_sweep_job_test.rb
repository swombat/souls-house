require "test_helper"

class TitleSweepJobTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
  end

  test "fallback picks another model family" do
    assert_equal "anthropic/claude-haiku-5.5", TitleSweepJob.fallback_for("openai/gpt-5-mini")[:model]
    assert_equal "openai/gpt-5.4-mini", TitleSweepJob.fallback_for("anthropic/claude-haiku-5.5")[:model]
    assert_equal "anthropic/claude-haiku-5.5", TitleSweepJob.fallback_for("google/gemini-2.5-flash")[:model]
    assert_equal "anthropic", TitleSweepJob.fallback_for(UtilityInference::TITLE_MODEL)[:provider]
  end

  test "titles an old untitled chat on the house key with the fallback model" do
    chat = untitled_chat(age: 6.minutes)
    calls = []
    UtilityInference.stub :house_chat, ->(model:, provider:, system:, user:, max_tokens:) {
      calls << [ model, provider ]
      assert_includes user, "Q4 marketing"
      "Q4 campaign plan"
    } do
      UtilityInference.stub :title, ->(**) { flunk "the account key is not used by the sweep" } do
        with_house_key { TitleSweepJob.perform_now }
      end
    end

    assert_equal [ [ "anthropic/claude-haiku-5.5", "anthropic" ] ], calls
    assert_equal "Q4 campaign plan", chat.reload.title
    assert_equal 1, chat.title_sweep_attempts
  end

  test "leaves young, titled, discarded and user-less chats alone" do
    young = untitled_chat(age: 4.minutes)
    titled = untitled_chat(age: 1.hour).tap { |chat| chat.update!(title: "Kept") }
    discarded = untitled_chat(age: 1.hour).tap(&:discard!)
    no_user = @account.chats.create!(model_id: "openai/gpt-5-mini")
    no_user.messages.create!(role: "assistant", content: "Hello")
    no_user.update_columns(created_at: 1.hour.ago)

    UtilityInference.stub :house_chat, ->(**) { flunk "nothing to sweep" } do
      with_house_key { TitleSweepJob.perform_now }
    end

    assert_nil young.reload.title
    assert_equal "Kept", titled.reload.title
    assert_nil discarded.reload.title
    assert_nil no_user.reload.title
  end

  test "gives up on a chat after three failed sweeps and keeps going past failures" do
    stuck = untitled_chat(age: 2.hours)
    other = untitled_chat(age: 1.hour)
    UtilityInference.stub :house_chat, ->(user:, **) {
      raise UtilityInference::InvalidResponse, "Empty house utility response" if user.include?("STUCK")
      "Fine title"
    } do
      stuck.messages.create!(role: "user", content: "STUCK")
      4.times { with_house_key { TitleSweepJob.perform_now } }
    end

    assert_nil stuck.reload.title
    assert_equal TitleSweepJob::MAX_ATTEMPTS, stuck.title_sweep_attempts
    assert_equal "Fine title", other.reload.title
    assert_equal 1, other.title_sweep_attempts
  end

  test "a blank answer uses an attempt and leaves the title unset" do
    chat = untitled_chat(age: 1.hour)
    UtilityInference.stub :house_chat, ->(**) { "   " } do
      with_house_key { TitleSweepJob.perform_now }
    end
    assert_nil chat.reload.title
    assert_equal 1, chat.title_sweep_attempts
  end

  test "is scheduled every ten minutes in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "title_sweep")
    assert_equal "TitleSweepJob", entry["class"]
    assert_equal "every 5 minutes", entry["schedule"]
  end

  test "without the house key nothing is asked and no attempt is spent" do
    chat = untitled_chat(age: 1.hour)
    HouseInference::Offering.stub :key, nil do
      OpenAI::Client.stub :new, ->(*) { flunk "No inference expected" } do
        4.times { TitleSweepJob.perform_now }
      end
    end
    assert_equal 0, chat.reload.title_sweep_attempts

    with_house_key do
      UtilityInference.stub :house_chat, ->(**) { "Named at last" } do
        TitleSweepJob.perform_now
      end
    end
    assert_equal "Named at last", chat.reload.title
  end

  test "an attempt another run already took is not taken again" do
    chat = untitled_chat(age: 1.hour)
    stale = Chat.find(chat.id)
    Chat.where(id: chat.id).update_all(title_sweep_attempts: TitleSweepJob::MAX_ATTEMPTS)
    job = TitleSweepJob.new
    refute job.send(:reserve_attempt, stale)
    assert_equal TitleSweepJob::MAX_ATTEMPTS, chat.reload.title_sweep_attempts

    other = untitled_chat(age: 1.hour)
    stale_other = Chat.find(other.id)
    assert job.send(:reserve_attempt, Chat.find(other.id))
    refute job.send(:reserve_attempt, stale_other), "the stale copy's count is out of date"
    assert_equal 1, other.reload.title_sweep_attempts
  end

  test "a run stops taking chats once its budget is spent" do
    first = untitled_chat(age: 1.hour)
    second = untitled_chat(age: 2.hours)
    calls = 0
    with_house_key do
      UtilityInference.stub :house_chat, ->(**) { calls += 1; travel TitleSweepJob::RUN_BUDGET + 1.second; "Title" } do
        TitleSweepJob.perform_now
      end
    end
    assert_equal 1, calls
    assert_equal "Title", first.reload.title
    assert_equal 0, second.reload.title_sweep_attempts
  end

  private

  def with_house_key(&)
    HouseInference::Offering.stub(:key, "sk-or-test", &)
  end

  def untitled_chat(age:)
    chat = @account.chats.create!(model_id: "openai/gpt-5-mini")
    chat.messages.create!(role: "user", content: "We need to plan our Q4 marketing campaign.")
    chat.update_columns(created_at: age.ago)
    chat
  end

end
