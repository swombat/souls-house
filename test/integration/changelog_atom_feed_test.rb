require "test_helper"

# Public Atom feed at /changelog.atom so visitors and feed readers can subscribe
# to changelog entries, with each entry linking to its own /changelog/<slug> page.
class ChangelogAtomFeedTest < ActionDispatch::IntegrationTest

  NS = { "atom" => Changelog::AtomFeed::XMLNS }.freeze

  test "changelog.atom is public, valid Atom 1.0, capped at FEED_LIMIT, and links each entry to its page" do
    get changelog_path(format: :atom)

    assert_response :success
    assert_equal "application/atom+xml", response.media_type
    assert_equal "utf-8", response.charset.downcase

    doc = Nokogiri::XML::Document.parse(response.body) { |config| config.strict }
    assert_equal Changelog::AtomFeed::XMLNS, doc.root.namespace.href
    assert_equal "Changelog — #{Setting.instance.site_name}", doc.at_xpath("/atom:feed/atom:title", NS).text
    assert_equal "http://www.example.com/changelog.atom", doc.at_xpath("/atom:feed/atom:link[@rel='self']/@href", NS).value
    assert_equal "http://www.example.com/changelog", doc.at_xpath("/atom:feed/atom:link[@rel='alternate']/@href", NS).value

    expected = Changelog.latest(Changelog::FEED_LIMIT)
    entries = doc.xpath("/atom:feed/atom:entry", NS)
    assert_equal expected.size, entries.size
    assert_operator entries.size, :<=, Changelog::FEED_LIMIT

    first = entries.first
    assert_equal expected.first[:title], first.at_xpath("atom:title", NS).text
    assert_equal "http://www.example.com/changelog/#{expected.first[:slug]}",
      first.at_xpath("atom:link[@rel='alternate']/@href", NS).value
    assert_equal expected.first[:published_at], first.at_xpath("atom:updated", NS).text
  end

  test "changelog.atom supports conditional GET with ETag and invalidates when an entry is corrected" do
    original_entries = Changelog.latest(Changelog::FEED_LIMIT)
    etag = nil

    Changelog.stub(:latest, ->(_limit) { original_entries }) do
      get changelog_path(format: :atom)
      assert_response :success
      assert_nil response.headers["Last-Modified"]
      etag = response.headers["ETag"]
      assert_predicate etag, :present?

      get changelog_path(format: :atom), headers: { "If-None-Match" => etag }
      assert_response :not_modified
    end

    # Correcting an entry's body without changing the top slug, published_at, or entry count
    # must invalidate the ETag and return 200 with the corrected XML.
    corrected_entries = original_entries.map(&:dup)
    corrected_entries[0][:body] = "#{corrected_entries[0][:body]} (corrected)"

    Changelog.stub(:latest, ->(_limit) { corrected_entries }) do
      get changelog_path(format: :atom), headers: { "If-None-Match" => etag }
      assert_response :success
      refute_equal etag, response.headers["ETag"]
      assert_includes response.body, "(corrected)"
    end
  end

  test "public pages advertise the Atom feed for autodiscovery" do
    entry = Changelog.entries.first
    expected_title = "Changelog — #{Setting.instance.site_name}"

    [ root_path, changelog_path, changelog_entry_path(entry[:slug]) ].each do |path|
      get path
      assert_response :success
      assert_select "link[rel='alternate'][type='application/atom+xml'][href='http://www.example.com/changelog.atom'][title=?]",
        expected_title
    end
  end

  test "the changelog page includes a direct link to the Atom feed" do
    assert_includes Rails.root.join("app/frontend/pages/changelog.svelte").read, %(href="/changelog.atom")
  end

end
