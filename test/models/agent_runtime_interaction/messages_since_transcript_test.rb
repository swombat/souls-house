require "test_helper"

# What a running resident can be shown mid-run: messages posted in its
# conversation after the transcript its run was built from. Reading them must
# never move the transcript cursor.
class AgentRuntimeInteraction::MessagesSinceTranscriptTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @user = users(:user_1)
    @chat = @agent.account.chats.create!(title: "Mid-run", manual_responses: true, agents: [ @agent, @other ])
    @seen = @chat.messages.create!(user: @user, role: "user", content: "Please look at the release.")
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    @run.update!(last_included_message_id: @seen.id)
  end

  test "empty when nothing has been posted since the transcript" do
    assert_equal [], @run.messages_since_transcript
  end

  test "carries people's and other residents' posts after the cursor, oldest first" do
    first = @chat.messages.create!(user: @user, role: "user", content: "  Also check the changelog.  ")
    second = @chat.messages.create!(agent: @other, role: "assistant", content: "I can take the changelog.")

    messages = @run.messages_since_transcript
    assert_equal [ first.obfuscated_id, second.obfuscated_id ], messages.map { |m| m[:id] }
    assert_equal "Also check the changelog.", messages.first[:text]
    assert_equal @user.email_address, messages.first[:author]
    assert_equal "human", messages.first[:author_type]
    assert_equal @other.name, messages.second[:author]
    assert_equal "agent", messages.second[:author_type]
    assert_equal first.created_at.iso8601(3), messages.first[:posted_at]
  end

  test "skips the resident's own posts, progress rows, streaming, discarded and empty rows" do
    @chat.messages.create!(agent: @agent, role: "assistant", content: "My own update.")
    @chat.messages.create!(agent: @other, role: "assistant", content: "working", progress_message: true)
    @chat.messages.create!(agent: @other, role: "assistant", content: "half a thought", streaming: true)
    @chat.messages.create!(user: @user, role: "user", content: "withdrawn", discarded_at: Time.current)
    @chat.messages.create!(agent: @other, role: "assistant", content: " \n")

    assert_equal [], @run.messages_since_transcript
  end

  test "keeps an attachment-only post and says how many files it carries" do
    post = @chat.messages.create!(agent: @other, role: "assistant", content: "")
    post.attachments.attach(io: StringIO.new("notes"), filename: "notes.txt", content_type: "text/plain")

    message = @run.messages_since_transcript.sole
    assert_equal post.obfuscated_id, message[:id]
    assert_equal 1, message[:attachments]
  end

  test "bounds the count and each text" do
    (AgentRuntimeInteraction::MID_RUN_MESSAGE_LIMIT + 2).times do |n|
      @chat.messages.create!(user: @user, role: "user", content: "message #{n}")
    end
    long = @chat.messages.create!(user: @user, role: "user", content: "x" * (AgentRuntimeInteraction::MID_RUN_MESSAGE_CHARS + 50))

    messages = @run.messages_since_transcript
    assert_equal AgentRuntimeInteraction::MID_RUN_MESSAGE_LIMIT, messages.length
    assert_equal long.obfuscated_id, messages.last[:id], "the newest are kept"
    assert_equal AgentRuntimeInteraction::MID_RUN_MESSAGE_CHARS, messages.last[:text].length
    assert messages.last[:truncated]
    assert_not messages.first[:truncated]
  end

  test "nothing for a finished run or one with no transcript yet" do
    @chat.messages.create!(user: @user, role: "user", content: "late")
    @run.update_columns(last_included_message_id: nil)
    assert_equal [], @run.messages_since_transcript

    @run.update_columns(last_included_message_id: @seen.id, finished_at: Time.current)
    assert_equal [], @run.messages_since_transcript
  end

  test "reading never moves the transcript cursor" do
    @run.update_columns(transport_status: 200, runtime_status: "ok")
    cursor = @chat.agent_transcript_cursor(@agent)
    assert_equal @seen.id, cursor

    @chat.messages.create!(user: @user, role: "user", content: "Mid-run note.")
    assert_equal 1, @run.messages_since_transcript.length

    assert_equal cursor, @chat.agent_transcript_cursor(@agent)
    assert_equal @seen.id, @run.reload.last_included_message_id
  end

  test "a message shown mid-run leaves its pending wake queued" do
    @chat.messages.create!(agent: @other, role: "assistant", content: "Over to you when you're free.")
    wake = PendingWake.queue!(chat: @chat, agent: @agent, requested_by: @other.name, requester_agent: @other)

    assert_equal 1, @run.messages_since_transcript.length
    assert PendingWake.open.exists?(wake.id), "a steer notice is not a reply"
  end

end
