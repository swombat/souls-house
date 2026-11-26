require "test_helper"

# Each changelog entry has its own public page, and its link preview is that
# entry's, in the HTML a crawler gets (no JavaScript runs for X or LinkedIn).
class ChangelogEntryPagesTest < ActionDispatch::IntegrationTest

  setup do
    @site = Setting.instance.site_name
  end

  test "an entry with a clip has its own page, signed out, previewing its title, body and poster" do
    entry = Changelog.entries.find { |e| e[:clip] }
    preview = LinkPreview.for_changelog_entry(entry)

    get changelog_entry_path(entry[:slug])

    assert_response :success
    assert_equal "changelog-entry", inertia_component
    assert_equal entry[:title], inertia_shared_props["entry"]["title"]
    assert_equal preview.description, inertia_shared_props["description"]
    assert entry[:body].squish.start_with?(preview.description.delete_suffix("...")), "the description is the start of the body"
    assert_operator preview.description.length, :<=, LinkPreview::DESCRIPTION_LENGTH

    assert_select "title", text: "#{entry[:title]} — #{@site}"
    assert_select "meta[name='description'][content=?]", preview.description
    assert_select "meta[property='og:url'][content=?]", "http://www.example.com/changelog/#{entry[:slug]}"
    assert_select "meta[property='og:title'][content=?]", "#{entry[:title]} — #{@site}"
    assert_select "meta[property='og:description'][content=?]", preview.description
    assert_select "meta[property='og:image'][content=?]", "http://www.example.com#{entry[:clip][:poster]}"
    assert_select "meta[property='og:video'][content=?]", "http://www.example.com#{entry[:clip][:src]}"
    assert_select "meta[property='og:video:type'][content='video/mp4']"
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
    assert_select "meta[name='twitter:card'][content='player']", count: 0
    assert_select "meta[name='twitter:image'][content=?]", "http://www.example.com#{entry[:clip][:poster]}"
  end

  test "an entry without a clip previews the hero still and offers no video" do
    entry = Changelog.entries.find { |e| !e[:clip] }

    get changelog_entry_path(entry[:slug])

    assert_response :success
    assert_select "meta[property='og:title'][content=?]", "#{entry[:title]} — #{@site}"
    assert_select "meta[property='og:image'][content='http://www.example.com/hero/film.jpg']"
    assert_select "meta[property='og:video']", count: 0
  end

  test "the page carries the entries either side" do
    entries = Changelog.entries
    get changelog_entry_path(entries[1][:slug])

    assert_equal entries[0][:slug], inertia_shared_props["entry"]["newer"]["slug"]
    assert_equal entries[2][:slug], inertia_shared_props["entry"]["older"]["slug"]
  end

  test "an unknown slug is a 404" do
    get "/changelog/no-such-change-ever"

    assert_response :not_found
  end

  # The visitor came to read one change; a loop beside the text they can't pause fights that.
  test "the entry page's clip waits to be played, with controls" do
    source = Rails.root.join("app/frontend/pages/changelog-entry.svelte").read

    assert_match(/<video[^>]*\bcontrols\b/m, source)
    refute_match(/\bautoplay\b/, source)
    refute_match(/^\s*loop$/, source)
  end

  test "the list and the home carousel link each entry to its page" do
    %w[app/frontend/lib/components/features/ChangelogList.svelte app/frontend/lib/components/home/ChangelogCarousel.svelte].each do |file|
      assert_includes Rails.root.join(file).read, "href={`/changelog/${entry.slug}`}", "#{file} should link each entry to its own page"
    end
    assert_equal Changelog.entries.first[:slug], begin
      get changelog_path
      inertia_shared_props["changelog"].first["slug"]
    end
  end

end
