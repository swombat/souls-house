require "test_helper"

class ResidentMessageContentTest < ActiveSupport::TestCase

  MARKER = "\uE200cite\uE202turn0search2\uE202turn0search0\uE201"

  test "removes complete citations without changing Markdown or source URLs" do
    content = "**Evidence**#{MARKER} [source](https://example.org/source?q=1)\nSecond\uE200cite\uE202turn12view3\uE201."
    assert_equal "**Evidence** [source](https://example.org/source?q=1)\nSecond.",
      ResidentMessageContent.normalize(content)
  end

  test "preserves incomplete malformed and unknown private-use sequences" do
    content = [
      "\uE200cite\uE202turn0search2",
      "\uE200cite\uE201",
      "\uE200cite\uE202unknown\uE201",
      "\uE200other\uE202turn0search2\uE201",
      "\uE200cite\uE202turn0search2\n\uE201"
    ].join("\n")
    assert_equal content, ResidentMessageContent.normalize(content)
  end

  test "preserves literal escaped Unicode examples" do
    content = '\uE200cite\uE202turn0search2\uE201'
    assert_equal content, ResidentMessageContent.normalize(content)
  end

  test "removes adjacent markers without disturbing Unicode prose or spacing" do
    assert_equal "Sí — evidence.  Next.",
      ResidentMessageContent.normalize("Sí — evidence.#{MARKER}#{MARKER}  Next.")
  end

  test "preserves matched inline code including longer delimiters and multiline spans" do
    content = "Prose#{MARKER} `#{MARKER}` and `` `#{MARKER}` `` and `line\n#{MARKER}`."
    assert_equal "Prose `#{MARKER}` and `` `#{MARKER}` `` and `line\n#{MARKER}`.",
      ResidentMessageContent.normalize(content)
  end

  test "unmatched inline delimiters do not hide prose citations" do
    assert_equal "Prose `example ", ResidentMessageContent.normalize("Prose `example #{MARKER}")
    assert_equal "`` `", ResidentMessageContent.normalize("``#{MARKER} `")
  end

  test "preserves backtick and tilde fences including longer closing delimiters" do
    content = "Before#{MARKER}\n  ```ruby\n#{MARKER}\n  ````\nAfter#{MARKER}\n~~~\n#{MARKER}\n~~~\n"
    assert_equal "Before\n  ```ruby\n#{MARKER}\n  ````\nAfter\n~~~\n#{MARKER}\n~~~\n",
      ResidentMessageContent.normalize(content)
  end

  test "shorter and mismatched fences do not close a code block" do
    content = "````\n#{MARKER}\n```\n~~~\n#{MARKER}\n"
    assert_equal content, ResidentMessageContent.normalize(content)
  end

  test "preserves an unclosed fenced block without inventing a closing fence" do
    content = "Before#{MARKER}\n```text\n#{MARKER}"
    assert_equal "Before\n```text\n#{MARKER}", ResidentMessageContent.normalize(content)
  end

  test "preserves nil and empty content and strips a marker-only message to empty" do
    assert_nil ResidentMessageContent.normalize(nil)
    assert_equal "", ResidentMessageContent.normalize("")
    assert_equal "", ResidentMessageContent.normalize(MARKER)
  end

end
