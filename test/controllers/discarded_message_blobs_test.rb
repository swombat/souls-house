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

  test "a text preview is served same-origin, never cached, and denied after discard" do
    notes = @chat.messages.create!(content: "Notes", role: "user", user: @user)
    notes.attachments.attach(io: StringIO.new("# Comparison\n\nNemotron wins."), filename: "comparison.md",
      content_type: "text/markdown", identify: false)
    files = notes.files_json.first
    url = files.fetch(:text_preview_url)

    get url
    assert_response :success
    assert_equal "# Comparison\n\nNemotron wins.", response.body
    assert_equal "private, no-store", response.headers["Cache-Control"]

    get files.fetch(:inline_url)
    assert_response :redirect

    notes.discard!
    get url
    assert_response :not_found
    get files.fetch(:inline_url)
    assert_response :not_found
  end

  test "a text preview of a forged id is not found" do
    get "/attachment_previews/not-a-signed-id/comparison.md"
    assert_response :not_found
  end

  test "an html preview is served sanitized, sandboxed, never cached, leaves source intact, and is denied after discard" do
    html = <<~HTML
      <!doctype html>
      <html>
        <head>
          <base href="https://evil.example/">
          <meta http-equiv="refresh" content="0;url=https://evil.example/bounce">
          <style>h1 { color: teal; }</style>
        </head>
        <body>
          <h1>Draft</h1>
          <p>See <a href="https://evil.example/link" target="_blank">the report</a>.</p>
          <form action="https://evil.example/post"><button formaction="https://evil.example/btn">Go</button></form>
          <script>alert(1)</script>
          <noscript><meta http-equiv="refresh" content="0;url=https://evil.example/ns"></noscript>
          <img src="https://evil.example/pixel.png" onerror="alert(2)">
          <img src="data:image/png;base64,iVBORw0KGgo=" alt="Safe">
        </body>
      </html>
    HTML
    msg = @chat.messages.create!(content: "Preview", role: "user", user: @user)
    msg.attachments.attach(io: StringIO.new(html), filename: "preview.html",
      content_type: "text/html", identify: false)
    files = msg.files_json.first
    url = files.fetch(:html_preview_url)
    source_url = files.fetch(:text_preview_url)

    get url
    assert_response :success
    assert_equal "text/html; charset=utf-8", response.content_type
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal SandboxedHtml::CONTENT_POLICY, response.headers["Content-Security-Policy"]
    assert_includes response.headers["Content-Security-Policy"], "sandbox;"
    assert_includes response.headers["Content-Security-Policy"], "script-src 'none'"
    assert_includes response.headers["Content-Security-Policy"], "default-src 'none'"

    doc = Nokogiri::HTML5.parse(response.body)
    assert_equal "Draft", doc.at_css("h1").text
    assert_includes doc.text, "See the report."
    assert_includes doc.at_css("style").text, "color: teal"
    assert_equal "data:image/png;base64,iVBORw0KGgo=", doc.at_css("img[alt='Safe']")["src"]
    %w[a base form button script noscript].each do |tag|
      assert_empty doc.css(tag), "Expected <#{tag}> to be removed from rendered preview"
    end
    assert_empty doc.css("meta[http-equiv]")
    assert_not_includes response.body, "evil.example"

    # Source view stays unchanged and serves the original bytes.
    get source_url
    assert_response :success
    assert_equal html, response.body

    msg.discard!
    get url
    assert_response :not_found
  end

  test "an html preview rejects non-html blobs, oversized blobs, and forged ids" do
    get "/attachment_html_previews/not-a-signed-id/preview.html"
    assert_response :not_found

    image_blob = @message.attachments.first.blob
    get "/attachment_html_previews/#{image_blob.signed_id}/test_image.png"
    assert_response :unsupported_media_type

    msg = @chat.messages.create!(content: "Huge HTML", role: "user", user: @user)
    msg.attachments.attach(io: StringIO.new("<h1>Big</h1>"), filename: "huge.html",
      content_type: "text/html", identify: false)
    huge_blob = msg.attachments.first.blob
    huge_blob.update_column(:byte_size, AttachmentHtmlPreviewsController::MAX_PREVIEW_BYTES + 1)

    assert_nil msg.reload.files_json.first[:html_preview_url]
    get "/attachment_html_previews/#{huge_blob.signed_id}/huge.html"
    assert_response :content_too_large
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
