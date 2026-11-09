require "test_helper"

class ToolShedEntryTest < ActiveSupport::TestCase

  FIXTURES = Rails.root.join("test/fixtures/files")

  test "reads an entry's fields and renders its body" do
    entry = ToolShedEntry.find("good", dir: FIXTURES.join("tool_shed"))

    assert_equal "Good tool", entry[:name]
    assert_equal "1.0", entry[:version]
    assert_equal [ "numpy" ], entry[:requires]
    assert_equal [ "A resident container" ], entry[:tested_in]
    assert_equal "separate", entry[:availability]
    assert_includes entry[:body_html], "<code"
  end

  test "an entry that names nowhere it was tested is refused" do
    error = assert_raises(ToolShedEntry::Invalid) { ToolShedEntry.all(dir: FIXTURES.join("tool_shed_bad")) }

    assert_match "tested_in", error.message
  end

  test "an unknown availability or a slug that does not match its folder is refused" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = FIXTURES.join("tool_shed/good/entry.md").read
      root.join("odd").mkpath
      root.join("odd/entry.md").write(source)
      assert_raises(ToolShedEntry::Invalid) { ToolShedEntry.all(dir: root) }

      root.join("odd/entry.md").write(source.sub("slug: good", "slug: odd").sub("availability: separate", "availability: maybe"))
      assert_raises(ToolShedEntry::Invalid) { ToolShedEntry.all(dir: root) }
    end
  end

  test "an entry with no install or use instructions is refused" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      front_matter = FIXTURES.join("tool_shed/good/entry.md").read.split(/^---\s*$/, 3)[1]
      root.join("good").mkpath
      root.join("good/entry.md").write("---#{front_matter}---\n\n")

      error = assert_raises(ToolShedEntry::Invalid) { ToolShedEntry.all(dir: root) }
      assert_match "install and use", error.message
    end
  end

  test "a list item YAML reads as a mapping is refused, not shown as a hash" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = FIXTURES.join("tool_shed/good/entry.md").read
      root.join("good").mkpath
      root.join("good/entry.md").write(source.sub("  - A resident container", "  - A resident container, 9 Nov: it ran"))

      error = assert_raises(ToolShedEntry::Invalid) { ToolShedEntry.all(dir: root) }
      assert_match "tested_in", error.message
    end
  end

  test "every entry in the shed is well formed" do
    assert_nothing_raised { ToolShedEntry.all }
  end

end
