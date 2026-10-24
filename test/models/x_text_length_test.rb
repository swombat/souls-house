require "test_helper"

# Expected values come from the official twitter-text 3.1.0 parseTweet (see
# script/x_text_length/README.md), never from this port.
class XTextLengthTest < ActiveSupport::TestCase

  OFFICIAL = JSON.parse(Rails.root.join("test/fixtures/files/x_text_length_official.json").read)

  test "agrees with official twitter-text on every fixture case" do
    mismatches = OFFICIAL.reject do |text, length, valid|
      result = XTextLength.parse(text)
      result[:weighted_length] == length && result[:valid] == valid
    end

    assert_operator OFFICIAL.size, :>, 3000
    assert_empty mismatches.first(5), "#{mismatches.size} of #{OFFICIAL.size} cases differ from twitter-text"
  end

  test "the boundaries raised in review" do
    assert_equal 281, XTextLength.weighted_length("#{"a" * 256} https://example.com,"), "trailing punctuation is not part of the URL"
    assert_equal 280, XTextLength.weighted_length("🇪🇸" * 140), "a flag is one emoji"
    assert_equal 280, XTextLength.weighted_length("1️⃣" * 140), "a keycap is one emoji"
    assert_equal 1, XTextLength.weighted_length("©"), "a text-presentation symbol is not an emoji"
    assert_equal 23, XTextLength.weighted_length("foo.house"), "any TLD twitter-text knows"
    assert_equal 8, XTextLength.weighted_length("file.txt"), "not a TLD"
    assert_equal 5, XTextLength.weighted_length("e.g.ß"), "Ruby's /i would read ß as ss"
  end

  test "limits" do
    assert XTextLength.valid?("a" * 280)
    assert_not XTextLength.valid?("a" * 281)
    assert_not XTextLength.valid?("日" * 141)
    assert_not XTextLength.valid?("   ")
    assert_not XTextLength.valid?("﻿hello"), "twitter-text rejects invalid characters"
  end

end
