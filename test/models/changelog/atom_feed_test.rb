require "test_helper"

class Changelog::AtomFeedTest < ActiveSupport::TestCase

  NS = { "atom" => Changelog::AtomFeed::XMLNS }.freeze

  test "renders valid Atom 1.0 XML with per-entry links, escaped HTML, and clip metadata" do
    entries = [
      {
        slug: "voice-mode",
        date: "2026-11-05",
        published_at: "2026-11-05T14:30:00Z",
        title: "Voice & <live> audio",
        body: "Speak directly with <residents> & hear replies.",
        clip: { name: "voice", src: "/changelog-clips/voice.mp4", poster: "/changelog-clips/voice.jpg" }
      },
      {
        slug: "plain-change",
        date: "2026-11-04",
        published_at: "2026-11-04T09:00:00Z",
        title: "Plain change",
        body: "No clip attached here."
      }
    ]

    xml = Changelog::AtomFeed.render(
      entries:,
      base_url: "https://souls.house/",
      site_name: "souls.house",
      subtitle: "Everything that has changed in souls.house, newest first."
    )

    doc = Nokogiri::XML::Document.parse(xml) { |config| config.strict }
    assert_equal "feed", doc.root.name
    assert_equal Changelog::AtomFeed::XMLNS, doc.root.namespace.href
    assert_equal "https://souls.house/changelog.atom", doc.at_xpath("/atom:feed/atom:id", NS).text
    assert_equal "Changelog — souls.house", doc.at_xpath("/atom:feed/atom:title", NS).text
    assert_equal "Everything that has changed in souls.house, newest first.", doc.at_xpath("/atom:feed/atom:subtitle", NS).text
    assert_equal "2026-11-05T14:30:00Z", doc.at_xpath("/atom:feed/atom:updated", NS).text
    assert_equal "souls.house", doc.at_xpath("/atom:feed/atom:author/atom:name", NS).text
    assert_equal "https://souls.house/changelog.atom", doc.at_xpath("/atom:feed/atom:link[@rel='self']/@href", NS).value
    assert_equal "https://souls.house/changelog", doc.at_xpath("/atom:feed/atom:link[@rel='alternate']/@href", NS).value

    nodes = doc.xpath("/atom:feed/atom:entry", NS)
    assert_equal 2, nodes.size

    first = nodes.first
    assert_equal "https://souls.house/changelog/voice-mode", first.at_xpath("atom:id", NS).text
    assert_equal "Voice & <live> audio", first.at_xpath("atom:title", NS).text
    assert_equal "https://souls.house/changelog/voice-mode", first.at_xpath("atom:link[@rel='alternate']/@href", NS).value
    assert_equal "2026-11-05T14:30:00Z", first.at_xpath("atom:published", NS).text
    assert_equal "2026-11-05T14:30:00Z", first.at_xpath("atom:updated", NS).text
    assert_equal "html", first.at_xpath("atom:content/@type", NS).value

    first_html = first.at_xpath("atom:content", NS).text
    assert_includes first_html, "Speak directly with &lt;residents&gt; &amp; hear replies."
    assert_includes first_html, "https://souls.house/changelog-clips/voice.jpg"
    assert_equal "https://souls.house/changelog-clips/voice.mp4",
      first.at_xpath("atom:link[@rel='enclosure'][@type='video/mp4']/@href", NS).value

    second = nodes.second
    assert_equal "https://souls.house/changelog/plain-change", second.at_xpath("atom:id", NS).text
    assert_nil second.at_xpath("atom:link[@rel='enclosure']", NS)
    refute_includes second.at_xpath("atom:content", NS).text, "<img"
  end

  test "renders a valid feed when there are no entries" do
    xml = Changelog::AtomFeed.render(
      entries: [],
      base_url: "https://souls.house",
      site_name: "souls.house",
      subtitle: "Changes."
    )

    doc = Nokogiri::XML::Document.parse(xml) { |config| config.strict }
    assert_empty doc.xpath("/atom:feed/atom:entry", NS)
    assert_predicate doc.at_xpath("/atom:feed/atom:updated", NS).text, :present?
  end

end
