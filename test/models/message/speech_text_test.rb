require "test_helper"

class Message::SpeechTextTest < ActiveSupport::TestCase

  test "replaces fenced code blocks with spoken marker" do
    text = "Here is some code:\n```ruby\nputs 'hello'\n```\nAnd more text."
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "I've included a code block here."
    assert_not_includes result, "puts 'hello'"
  end

  test "strips inline code backticks but keeps text" do
    text = "Use the `Array#map` method to transform data."
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "Array#map"
    assert_not_includes result, "`"
  end

  test "removes image markdown" do
    text = "Look at this: ![alt text](http://example.com/img.png) nice!"
    result = Message::SpeechText.new(text).to_s
    assert_not_includes result, "![alt text]"
    assert_not_includes result, "http://example.com/img.png"
    assert_includes result, "nice!"
  end

  test "converts links to plain text" do
    text = "Check out [this link](http://example.com) for details."
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "this link"
    assert_not_includes result, "http://example.com"
    assert_not_includes result, "["
    assert_not_includes result, "]"
  end

  test "removes raw URLs" do
    text = "Visit https://example.com/page for more info."
    result = Message::SpeechText.new(text).to_s
    assert_not_includes result, "https://example.com/page"
    assert_includes result, "Visit"
  end

  test "removes standalone action markers (stage directions)" do
    text = "Hello there.\n*sits with this*\nHow are you?"
    result = Message::SpeechText.new(text).to_s
    assert_not_includes result, "sits with this"
    assert_includes result, "Hello there."
    assert_includes result, "How are you?"
  end

  test "preserves emphasis within sentences (strips asterisks, keeps text)" do
    text = "This is **really** important and *quite* nice."
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "really"
    assert_includes result, "quite"
    assert_not_includes result, "**"
    refute_match(/\*/, result)
  end

  test "preserves ElevenLabs tonal tags" do
    text = "[whispers] I have a secret. [excited] This is amazing!"
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "[whispers]"
    assert_includes result, "[excited]"
    assert_includes result, "I have a secret."
  end

  test "strips heading markers" do
    text = "# Heading 1\n## Heading 2\n### Heading 3"
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "Heading 1"
    assert_includes result, "Heading 2"
    assert_includes result, "Heading 3"
    assert_not_includes result, "#"
  end

  test "strips strikethrough formatting" do
    text = "This is ~~deleted~~ text."
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "deleted"
    assert_not_includes result, "~~"
  end

  test "strips unordered list markers" do
    text = "- Item one\n* Item two\n+ Item three"
    assert_equal "Item one\nItem two\nItem three", Message::SpeechText.new(text).to_s
  end

  test "strips ordered list markers" do
    text = "1. First\n2. Second\n3. Third"
    assert_equal "First\nSecond\nThird", Message::SpeechText.new(text).to_s
  end

  test "strips blockquotes" do
    text = "> This is a quote"
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "This is a quote"
    assert_not_includes result, ">"
  end

  test "strips horizontal rules" do
    text = "Before\n---\nAfter"
    result = Message::SpeechText.new(text).to_s
    assert_includes result, "Before"
    assert_includes result, "After"
    assert_not_includes result, "---"
  end

  test "collapses multiple blank lines" do
    text = "First paragraph.\n\n\n\n\nSecond paragraph."
    result = Message::SpeechText.new(text).to_s
    assert_not_includes result, "\n\n\n"
    assert_includes result, "First paragraph."
    assert_includes result, "Second paragraph."
  end

  test "truncates to MAX_LENGTH characters" do
    long_text = "a" * 6000
    result = Message::SpeechText.new(long_text).to_s
    assert result.length <= Message::SpeechText::MAX_LENGTH
  end

  test "returns empty string for blank content" do
    assert_equal "", Message::SpeechText.new(nil).to_s
    assert_equal "", Message::SpeechText.new("").to_s
    assert_equal "", Message::SpeechText.new("   ").to_s
  end

  test "handles complex markdown document" do
    text = <<~MD
      # Welcome

      Here is some **bold** and *italic* text.

      ```python
      def hello():
          print("world")
      ```

      Check [this link](http://example.com) and ![image](http://img.com/a.png).

      > A blockquote

      - List item one
      - List item two

      Visit https://raw-url.com for more.

      [sarcastically] Oh, how wonderful.
    MD

    result = Message::SpeechText.new(text).to_s
    assert_includes result, "Welcome"
    assert_includes result, "bold"
    assert_includes result, "italic"
    assert_includes result, "I've included a code block here."
    assert_includes result, "this link"
    assert_includes result, "A blockquote\n\nList item one", "the paragraph break before a list is a pause in speech"
    assert_includes result, "[sarcastically]"
    assert_not_includes result, "```"
    assert_not_includes result, "http://example.com"
    assert_not_includes result, "https://raw-url.com"
    assert_not_includes result, "![image]"
  end

end
