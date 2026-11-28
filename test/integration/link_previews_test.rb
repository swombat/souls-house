require "test_helper"

# Crawlers (X, LinkedIn, WhatsApp, Slack) read the server's HTML and never run
# the page, so these assert on the raw response, with no JavaScript.
class LinkPreviewsTest < ActionDispatch::IntegrationTest

  PAGES = {
    pricing: "/pricing",
    features: "/features",
    changelog: "/changelog",
    tool_shed: "/tool-shed",
    companion: "/companion",
    self_host: "/self-host",
    self_host_technical: "/self-host/technical",
    decisions: "/decisions",
    data_model: "/data-model",
    privacy: "/privacy",
    terms: "/terms",
    safeguard_responses: "/safeguard-responses"
  }.freeze

  SVELTE_PAGES = {
    pricing: "app/frontend/pages/pricing.svelte",
    features: "app/frontend/pages/features.svelte",
    changelog: "app/frontend/pages/changelog.svelte",
    tool_shed: "app/frontend/pages/tool-shed/index.svelte",
    companion: "app/frontend/pages/companion.svelte",
    self_host: "app/frontend/pages/self-host.svelte",
    self_host_technical: "app/frontend/pages/self-host-technical.svelte",
    decisions: "app/frontend/pages/decisions/index.svelte",
    privacy: "app/frontend/pages/privacy.svelte",
    terms: "app/frontend/pages/terms.svelte",
    safeguard_responses: "app/frontend/pages/safeguard-responses.svelte"
  }.freeze

  PAGES.each do |key, path|
    test "#{path} gives crawlers its own title, description and image" do
      preview = LinkPreview.for(key)

      get path

      assert_response :success
      assert_page_card(preview:, path:)
    end
  end

  test "every static link_previews.json entry is covered by PAGES" do
    assert_equal LinkPreview.entries.keys.sort, PAGES.keys.map(&:to_s).sort
  end

  test "/decisions/:slug gives crawlers the decision's title and summary" do
    decision = Decision.all.first
    preview = LinkPreview.for_decision(decision)

    get decision_path(decision[:slug])

    assert_response :success
    assert_page_card(preview:, path: "/decisions/#{decision[:slug]}")
    assert_equal preview.description, inertia_shared_props["description"]
    assert_operator preview.description.length, :<=, LinkPreview::DESCRIPTION_LENGTH

    source = Rails.root.join("app/frontend/pages/decisions/show.svelte").read
    assert_includes source, "<title>{decision.title} — {$siteName}</title>"
    assert_includes source, '<meta name="description" content={description} />'
  end

  test "/data-model/:area gives crawlers the area's title and summary" do
    area = DataModel.find("billing")
    preview = LinkPreview.for_data_model_area(area)

    get data_model_path(area.id)

    assert_response :success
    assert_page_card(preview:, path: "/data-model/#{area.id}")
    assert_equal({ "title" => preview.title, "description" => preview.description }, inertia_shared_props["preview"])
    assert_operator preview.description.length, :<=, LinkPreview::DESCRIPTION_LENGTH

    source = Rails.root.join("app/frontend/pages/data-model.svelte").read
    assert_includes source, "<title>{preview.title} — {$siteName}</title>"
    assert_includes source, '<meta name="description" content={preview.description} />'
  end

  test "/tool-shed/:slug gives crawlers the tool's title and summary" do
    tool = ToolShedEntry.find("good", dir: Rails.root.join("test/fixtures/files/tool_shed"))
    preview = LinkPreview.for_tool_shed_entry(tool)

    ToolShedEntry.stub(:find, tool) do
      get tool_shed_tool_path(tool[:slug])
    end

    assert_response :success
    assert_page_card(preview:, path: "/tool-shed/#{tool[:slug]}")
    assert_equal preview.description, inertia_shared_props["description"]
    assert_operator preview.description.length, :<=, LinkPreview::DESCRIPTION_LENGTH

    source = Rails.root.join("app/frontend/pages/tool-shed/show.svelte").read
    assert_includes source, "<title>{tool.name} — {linkPreviews.tool_shed.title} — {$siteName}</title>"
    assert_includes source, '<meta name="description" content={description} />'
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

  private

  def assert_page_card(preview:, path:)
    site = Setting.instance.site_name
    title = preview.page_title(site)

    assert_select "title", text: title
    assert_select "meta[name='description'][content=?]", preview.description
    assert_select "meta[property='og:title'][content=?]", title
    assert_select "meta[property='og:description'][content=?]", preview.description
    assert_select "meta[property='og:url'][content=?]", "http://www.example.com#{path}"
    assert_select "meta[property='og:site_name'][content=?]", site
    assert_select "meta[property='og:type'][content='website']"
    assert_select "meta[property='og:image'][content='http://www.example.com/hero/film.jpg']"
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
    assert_select "meta[name='twitter:title'][content=?]", title
    assert_select "meta[name='twitter:description'][content=?]", preview.description
    assert_select "meta[name='twitter:image'][content='http://www.example.com/hero/film.jpg']"
    assert_select "meta[property='og:video']", count: 0
  end

end
