require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "active_support/all"
require "action_view"
require "rails/engine"
require "vite_rails"

class ViteUpgradeTest < Minitest::Test

  def test_project_plugin_matches_the_ruby_gem_without_disabling_the_guard
    root = Pathname.new(File.expand_path("../..", __dir__))
    config = ViteRuby.new(root: root, mode: "production").config
    refute config.skip_compatibility_check
    ViteRuby::CompatibilityCheck.verify_plugin_version(root)
    assert_raises(ArgumentError) do
      ViteRuby::CompatibilityCheck.raise_unless_satisfied("^5.1.1", ViteRuby::DEFAULT_PLUGIN_VERSION)
    end
  end

  def test_production_manifest_renders_script_preload_and_nested_styles
    Dir.mktmpdir("vite-manifest-") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/vite.json"), JSON.generate(all: { autoBuild: false }))
      vite = ViteRuby.new(root: root, mode: "production")
      path = vite.config.known_manifest_paths.first
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.generate(
        "entrypoints/application.js" => { "file" => "assets/application-test.js", "isEntry" => true,
          "imports" => [ "_shared.js" ], "css" => [ "assets/application-test.css" ] },
        "_shared.js" => { "file" => "assets/shared-test.js", "css" => [ "assets/shared-test.css" ] }))
      view = ActionView::Base.empty
      view.extend(ViteRails::TagHelpers)
      view.define_singleton_method(:vite_manifest) { vite.manifest }
      html = view.vite_javascript_tag("application")
      assert_includes html, 'type="module"'
      assert_includes html, 'src="/vite/assets/application-test.js"'
      assert_includes html, 'rel="modulepreload"'
      assert_includes html, 'href="/vite/assets/shared-test.js"'
      assert_includes html, 'href="/vite/assets/application-test.css"'
      assert_includes html, 'href="/vite/assets/shared-test.css"'
      refute_includes html, "@vite/client"
      assert_nil view.vite_client_tag
    end
  end

end
