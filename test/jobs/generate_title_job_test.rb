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

  test "enqueues job after chat creation" do
    assert_enqueued_with(job: GenerateTitleJob) do
      @account.chats.create!(model_id: "openai/gpt-5-mini")
    end
  end

  test "does not enqueue job when title is preset" do
    assert_no_enqueued_jobs(only: GenerateTitleJob) do
      @account.chats.create!(model_id: "openai/gpt-5-mini", title: "Preset")
    end
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

  test "missing utility credentials leaves title unset" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    chat = build_chat_with_conversation(model_id: "openai/gpt-5-mini")
    OpenAI::Client.stub :new, ->(*) { flunk "No inference expected" } do
      GenerateTitleJob.perform_now(chat)
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
