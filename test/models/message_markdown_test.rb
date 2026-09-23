require "test_helper"

class MessageMarkdownTest < ActiveSupport::TestCase

  test "underscored identifiers remain literal in prose" do
    content = "role, text, sent_at, media_kind inclusion, media_status inclusion"

    assert_equal "<p>#{content}</p>\n", Message.new(content: content).content_html
  end

  test "underscored prose does not consume subsequent bold and inline code" do
    message = Message.new(
      content: 'video_note, video — there is no `audio` branch, so **`media_kind == "audio"` is never produced inbound**'
    )

    assert_equal(
      "<p>video_note, video — there is no <code>audio</code> branch, so " \
      "<strong><code>media_kind == &quot;audio&quot;</code> is never produced inbound</strong></p>\n",
      message.content_html
    )
  end

  test "ordinary emphasis bold and inline code remain supported" do
    message = Message.new(content: "_ordinary emphasis_ and **bold** and `snake_case`")

    assert_equal(
      "<p><em>ordinary emphasis</em> and <strong>bold</strong> and <code>snake_case</code></p>\n",
      message.content_html
    )
  end

end
