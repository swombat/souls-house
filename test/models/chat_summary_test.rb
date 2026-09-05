require "test_helper"

class ChatSummaryTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
  end

  test "summary_stale? returns true when no summary generated" do
    assert @chat.summary_stale?
  end

  test "summary_stale? returns false when summary recently generated" do
    @chat.update!(summary: "Test summary", summary_generated_at: 30.minutes.ago)
    assert_not @chat.summary_stale?
  end

  test "summary_stale? returns true when summary older than cooldown" do
    @chat.update!(summary: "Test summary", summary_generated_at: 2.hours.ago)
    assert @chat.summary_stale?
  end

  test "historical summary stays readable" do
    @chat.update!(summary: "Existing summary", summary_generated_at: 30.minutes.ago)
    assert_equal "Existing summary", @chat.reload.summary
  end

  test "adding messages no longer generates summaries inline" do
    @chat.messages.create!(content: "Hello", role: "user", user: @user)
    assert_nil @chat.reload.summary
    assert_not @chat.respond_to?(:generate_summary!)
  end

  test "transcript_for_api returns formatted messages" do
    @chat.messages.create!(content: "Hello", role: "user", user: @user)
    @chat.messages.create!(content: "Hi there", role: "assistant")

    transcript = @chat.transcript_for_api

    assert_equal 2, transcript.length
    assert_equal "user", transcript.first[:role]
    assert_equal "Hello", transcript.first[:content]
    assert transcript.first[:timestamp].present?
    assert transcript.first[:author].present?
  end

  test "transcript_for_api excludes system messages" do
    @chat.messages.create!(content: "Hello", role: "user", user: @user)
    @chat.messages.create!(content: "System info", role: "system")
    @chat.messages.create!(content: "Response", role: "assistant")

    transcript = @chat.transcript_for_api

    assert_equal 2, transcript.length
    roles = transcript.map { |m| m[:role] }
    assert_not_includes roles, "system"
  end

  test "transcript_for_api includes author name from user" do
    @user.profile.update!(first_name: "Test", last_name: "User")
    @chat.messages.create!(content: "Hello", role: "user", user: @user)

    transcript = @chat.transcript_for_api
    assert_equal "Test User", transcript.first[:author]
  end

  test "transcript_for_api includes author from agent" do
    agent = @account.agents.create!(name: "Test Agent", colour: "blue", icon: "Brain")
    @chat.messages.create!(content: "Agent response", role: "assistant", agent: agent)

    transcript = @chat.transcript_for_api
    assert_equal "Test Agent", transcript.first[:author]
  end

  test "transcript_for_api includes authenticated attachment metadata" do
    message = @chat.messages.create!(content: "Please review this", role: "user", user: @user)
    message.attachments.attach(
      io: file_fixture("test_document.pdf").open,
      filename: "draft.pdf",
      content_type: "application/pdf"
    )

    attachment = @chat.transcript_for_api.first.fetch(:attachments).first

    assert_equal "draft.pdf", attachment.fetch(:filename)
    assert_equal "application/pdf", attachment.fetch(:content_type)
    assert_equal message.attachments.first.byte_size, attachment.fetch(:byte_size)
    assert_equal(
      Rails.application.routes.url_helpers.api_v1_conversation_message_attachment_path(
        @chat,
        message,
        message.attachments_attachments.first
      ),
      attachment.fetch(:download_path)
    )
  end

  test "summary is included in json_attributes" do
    @chat.update!(summary: "Test summary")
    json = @chat.as_json

    assert_equal "Test summary", json["summary"]
  end

end
