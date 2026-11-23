require "test_helper"

# Crawlers (X, LinkedIn, WhatsApp, Slack) read the server's HTML and never run
# the page, so these assert on the raw response, with no JavaScript.
class LinkPreviewsTest < ActionDispatch::IntegrationTest

  PAGES = {
    pricing: "/pricing",
    features: "/features",
    changelog: "/changelog",
    tool_shed: "/tool-shed"
  }.freeze

  SVELTE_PAGES = {
    pricing: "app/frontend/pages/pricing.svelte",
    features: "app/frontend/pages/features.svelte",
    changelog: "app/frontend/pages/changelog.svelte",
    tool_shed: "app/frontend/pages/tool-shed/index.svelte"
  }.freeze

  PAGES.each do |key, path|
    test "#{path} gives crawlers its own title, description and image" do
      preview = LinkPreview.for(key)
      site = Setting.instance.site_name

      get path

      assert_response :success
      assert_select "title", text: "#{preview.title} — #{site}"
      assert_select "meta[name='description'][content=?]", preview.description
      assert_select "meta[property='og:title'][content=?]", "#{preview.title} — #{site}"
      assert_select "meta[property='og:description'][content=?]", preview.description
      assert_select "meta[property='og:url'][content=?]", "http://www.example.com#{path}"
      assert_select "meta[property='og:site_name'][content=?]", site
      assert_select "meta[property='og:type'][content='website']"
      assert_select "meta[property='og:image'][content='http://www.example.com/hero/film.jpg']"
      assert_select "meta[name='twitter:card'][content='summary_large_image']"
      assert_select "meta[name='twitter:title'][content=?]", "#{preview.title} — #{site}"
      assert_select "meta[name='twitter:description'][content=?]", preview.description
      assert_select "meta[name='twitter:image'][content='http://www.example.com/hero/film.jpg']"
      assert_select "meta[property='og:video']", count: 0
    end
  end

  test "the homepage keeps its film preview and gets no page card" do
    get root_path

    assert_select "meta[property='og:video'][content$='/hero/film.mp4']"
    assert_select "meta[name='twitter:card'][content='player']"
    assert_select "meta[name='twitter:card'][content='summary_large_image']", count: 0
    assert_select "meta[property='og:type'][content='website']", count: 0
  end

  test "the preview image is in public" do
    assert Rails.public_path.join(LinkPreview::IMAGE_PATH.delete_prefix("/")).file?
  end

  # The Svelte heads read the same entries, so the words a visitor's tab shows
  # and the words a crawler sees can't drift apart.
  SVELTE_PAGES.each do |key, file|
    test "#{file} takes its head from the shared link preview entry" do
      source = Rails.root.join(file).read

      assert_includes source, "import linkPreviews from '$lib/link-previews'"
      assert_includes source, "linkPreviews.#{key}.title"
      assert_includes source, "linkPreviews.#{key}.description"
      refute_includes source, LinkPreview.for(key).description, "#{file} repeats the description instead of importing it"
    end
  end

end
