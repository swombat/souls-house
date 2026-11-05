require "test_helper"
require "support/vcr_setup"

class GenerateTitleJobTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
  end

  test "generates concise title for chat" do
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")

    UtilityInference.stub :title, ->(account:, model:, system:, user:) {
      assert_equal @account, account
      assert_equal "google/gemini-2.5-flash", model
      assert_includes system, "3 to 5 words"
      assert_includes user, "Q4 marketing campaign"
      "Q4 marketing campaign"
    } do
      GenerateTitleJob.perform_now(chat)
    end

    assert chat.reload.title.present?, "Chat should have a generated title"
    assert chat.title.downcase.include?("q4") || chat.title.downcase.include?("campaign") || chat.title.downcase.include?("marketing"),
      "Title '#{chat.title}' should be related to the Q4 marketing campaign conversation"
  end

  test "skips chat that already has a title" do
    chat = @account.chats.create!(model_id: "openai/gpt-5-mini", title: "Existing Title")

    assert_no_changes -> { chat.reload.title } do
      GenerateTitleJob.perform_now(chat)
    end
  end

  test "skips chat with no user messages" do
    chat = @account.chats.create!(model_id: "openai/gpt-5-mini")
    chat.messages.create!(role: "assistant", content: "Welcome! How can I help?")

    GenerateTitleJob.perform_now(chat)

    assert_nil chat.reload.title
  end

  # Daniel, YAqgdY 2026-11-04: a chat born empty (the voice wave on New
  # Chat) got no title request when its first message landed.
  test "an empty chat asks for no title until its first person's message, then exactly once" do
    chat = nil
    assert_no_enqueued_jobs(only: GenerateTitleJob) do
      chat = @account.chats.create!(model_id: "openai/gpt-5-mini")
      chat.messages.create!(role: "assistant", content: "Hello, I'm listening.")
    end

    assert_enqueued_jobs 1, only: GenerateTitleJob do
      chat.messages.create!(role: "user", content: "Audio conversation issues on the walk")
    end
    assert_enqueued_with(job: GenerateTitleJob, args: [ chat ])

    assert_no_enqueued_jobs(only: GenerateTitleJob) do
      chat.messages.create!(role: "user", content: "And a second message")
    end
  end

  test "a chat born with its first message asks once" do
    user = @account.users.first
    assert_enqueued_jobs 1, only: GenerateTitleJob do
      Chat.create_with_message!({ account: @account, model_id: "openai/gpt-5-mini", manual_responses: true,
                                 agents: [ @account.agents.create!(name: "Resident", runtime: "external") ] },
        message_content: "Plan the Q4 campaign", user: user)
    end
  end

  test "does not ask when the title is preset" do
    assert_no_enqueued_jobs(only: GenerateTitleJob) do
      chat = @account.chats.create!(model_id: "openai/gpt-5-mini", title: "Preset")
      chat.messages.create!(role: "user", content: "First message")
    end
  end

  test "a first message after the earlier one was discarded still does not ask twice" do
    chat = @account.chats.create!(model_id: "openai/gpt-5-mini")
    first = chat.messages.create!(role: "user", content: "First")
    first.discard!

    assert_enqueued_jobs 1, only: GenerateTitleJob do
      chat.messages.create!(role: "user", content: "Second, now the earliest kept")
    end
  end

  # Two first messages committing out of id order can both enqueue (Mira,
  # #774). The jobs share one per-chat slot, so the second runs after the
  # first and, finding its title, makes no call.
  test "title jobs for one chat run one at a time and the later one pays for nothing" do
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")
    other = build_chat_with_conversation(model_id: "openai/gpt-5-mini")

    assert_equal 1, GenerateTitleJob.concurrency_limit
    assert_equal GenerateTitleJob.new(chat).concurrency_key, GenerateTitleJob.new(Chat.find(chat.id)).concurrency_key
    assert_not_equal GenerateTitleJob.new(chat).concurrency_key, GenerateTitleJob.new(other).concurrency_key

    calls = 0
    UtilityInference.stub :title, ->(**) { calls += 1; "Q4 campaign plan" } do
      GenerateTitleJob.perform_now(Chat.find(chat.id))
      GenerateTitleJob.perform_now(Chat.find(chat.id))
    end
    assert_equal 1, calls
    assert_equal "Q4 campaign plan", chat.reload.title
  end

  test "an account without its own key is titled on the house key straight away" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")
    calls = []
    UtilityInference.stub :house_chat, ->(model:, provider:, system:, user:, max_tokens:) {
      calls << [ model, provider ]
      "Q4 campaign plan"
    } do
      HouseInference::Offering.stub(:key, "sk-or-test") { GenerateTitleJob.perform_now(chat) }
    end

    assert_equal [ [ "anthropic/claude-haiku-5.5", "anthropic" ] ], calls
    assert_equal "Q4 campaign plan", chat.reload.title
    assert_equal 1, chat.title_sweep_attempts, "the house call spends one of the sweep's attempts"
  end

  test "an account key that fails falls through to the house key" do
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")
    UtilityInference.stub :title, ->(**) { raise UtilityInference::InvalidResponse, "404" } do
      UtilityInference.stub :house_chat, ->(**) { "Q4 campaign plan" } do
        HouseInference::Offering.stub(:key, "sk-or-test") { GenerateTitleJob.perform_now(chat) }
      end
    end

    assert_equal "Q4 campaign plan", chat.reload.title
  end

  test "the house key is not used once the sweep's attempts are spent" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")
    chat.update_columns(title_sweep_attempts: TitleSweepJob::MAX_ATTEMPTS)
    UtilityInference.stub :house_chat, ->(**) { flunk "attempts are spent" } do
      HouseInference::Offering.stub(:key, "sk-or-test") { GenerateTitleJob.perform_now(chat) }
    end

    assert_nil chat.reload.title
  end

  test "title prompt bounds transcript input" do
    chat = @account.chats.create!(title: "Prompt input test")
    14.times { |index| chat.messages.create!(role: "assistant", content: "#{index} #{"x" * 500}") }
    captured = nil
    UtilityInference.stub :title, ->(**options) { captured = options; "Bounded title" } do
      assert_equal "Bounded title", GenerateTitlePrompt.new(chat: chat).generate_title
    end
    lines = captured.fetch(:user).lines.grep(/^- Assistant:/)
    assert_equal 12, lines.size
    assert lines.all? { |line| line.strip.length <= 253 }
    refute_includes captured.fetch(:user), "Assistant: 12 "
  end

  test "no account key and no house key leaves title unset" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")
    OpenAI::Client.stub :new, ->(*) { flunk "No inference expected" } do
      HouseInference::Offering.stub(:key, nil) { GenerateTitleJob.perform_now(chat) }
    end
    assert_nil chat.reload.title
  end

  private

  def build_chat_with_conversation(model_id:)
    chat = @account.chats.create!(model_id: model_id)

    chat.messages.create!(role: "user", content: "We need to plan our Q4 marketing campaign focused on the new product release and social media push.")
    chat.messages.create!(role: "assistant", content: "Let's outline goals, timelines, and assign channel owners so we can launch smoothly.")
    chat.messages.create!(role: "user", content: "Great, please coordinate with design for refreshed assets and confirm the Monday kickoff.")

    chat
  end

end
