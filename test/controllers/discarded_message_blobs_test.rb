require "test_helper"

# Issue #94 PR B: retained files of a discarded message are not reachable
# through signed ActiveStorage URLs issued before the discard.
class DiscardedMessageBlobsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:confirmed_user)
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Discarded blobs")
    @message = @chat.messages.create!(content: "Picture", role: "user", user: @user)
    @message.attachments.attach(
      io: file_fixture("test_image.png").open,
      filename: "test_image.png",
      content_type: "image/png"
    )
  end

  test "an old blob URL works again after restore" do
    url = @message.files_json.first.fetch(:url)
    @message.discard!
    get url
    assert_response :not_found

    @message.undiscard!
    get url
    assert_response :redirect
  end

  test "an old variant URL is denied after discard" do
    url = @message.files_json.first.fetch(:thumb_url)
    @message.discard!
    get url
    assert_response :not_found
  end

  test "a blob still attached to a kept message stays reachable" do
    copy = @chat.messages.create!(content: "Forked copy", role: "user", user: @user)
    copy.attachments.attach(@message.attachments.first.blob)
    url = @message.files_json.first.fetch(:url)
    @message.discard!
    get url
    assert_response :redirect
  end

  test "an old audio URL is denied after discard" do
    @message.audio_recording.attach(io: file_fixture("test_audio.webm").open, filename: "a.webm", content_type: "audio/webm")
    url = @message.audio_url
    @message.discard!
    get url
    assert_response :not_found
  end

end
