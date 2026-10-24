require "test_helper"

# Issue #94 PR B: retained files of a discarded message or its conversation
# are not reachable through signed ActiveStorage URLs issued before discard.
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

  test "old blob and variant URLs are hidden by a discarded chat and work again after restore" do
    files = @message.files_json.first
    urls = [ files.fetch(:url), files.fetch(:thumb_url) ]

    @chat.discard!
    urls.each do |url|
      get url
      assert_response :not_found
    end

    @chat.undiscard!
    urls.each do |url|
      get url
      assert_response :redirect
    end
  end

  test "an individually discarded message stays hidden after its chat is restored" do
    url = @message.files_json.first.fetch(:url)
    @message.discard!
    @chat.discard!
    @chat.undiscard!

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

  test "a kept message in a kept chat keeps a blob live against a discarded chat owner" do
    kept_chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Kept blob owner")
    kept_message = kept_chat.messages.create!(content: "Shared picture", role: "user", user: @user)
    kept_message.attachments.attach(@message.attachments.first.blob)
    url = @message.files_json.first.fetch(:url)

    @chat.discard!

    get url
    assert_response :redirect
  end

  test "a kept message in a discarded chat cannot keep a discarded message in a kept chat live" do
    blob = @message.attachments.first.blob
    discarded_chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Discarded parent")
    kept_message = discarded_chat.messages.create!(content: "Shared picture", role: "user", user: @user)
    kept_message.attachments.attach(blob)
    url = @message.files_json.first.fetch(:url)

    @message.discard!
    discarded_chat.discard!

    assert_not kept_message.discarded?
    get url
    assert_response :not_found
  end

  test "an old audio URL is denied after discard" do
    @message.audio_recording.attach(
      io: file_fixture("test_audio.webm").open,
      filename: "a.webm",
      content_type: "audio/webm"
    )
    url = @message.audio_url
    @message.discard!
    get url
    assert_response :not_found
  end

  test "an old audio URL is hidden by a discarded chat and works again after restore" do
    @message.audio_recording.attach(
      io: file_fixture("test_audio.webm").open,
      filename: "a.webm",
      content_type: "audio/webm"
    )
    url = @message.audio_url

    @chat.discard!
    get url
    assert_response :not_found

    @chat.undiscard!
    get url
    assert_response :redirect
  end

end
