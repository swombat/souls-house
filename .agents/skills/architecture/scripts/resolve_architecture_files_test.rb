require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"

class ResolveArchitectureFilesTest < Minitest::Test
  SCRIPT = File.expand_path("resolve_architecture_files.rb", __dir__)

  def setup
    @root = Dir.mktmpdir("architecture-resolver")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def family(shelf)
    write("docs/#{shelf}/requirements/260930-01-client.md")
    write("docs/#{shelf}/plans/260930-01a-client.md")
    write("docs/#{shelf}/plans/260930-01b-client.md")
    write("docs/#{shelf}/plans/260930-01c-client-dhh-feedback.md")
  end

  def write(path)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "# Synthetic fixture\n")
  end

  def resolve(argument)
    stdout, stderr, status = Open3.capture3("ruby", SCRIPT, argument, chdir: @root)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def test_archived_stem_remains_readable_without_recreating_old_directories
    family(".bak")
    result = resolve("260930-01-client")
    assert_equal "docs/.bak/plans/260930-01b-client.md", result.fetch("final_plan")
    refute Dir.exist?(File.join(@root, "docs/plans"))
  end

  def test_new_proposal_works_without_an_archive
    family("proposals")
    result = resolve("docs/proposals/requirements/260930-01-client.md")
    assert_equal "docs/proposals/plans/260930-01b-client.md", result.fetch("final_plan")
  end

  def test_active_requirement_wins_for_an_unqualified_stem
    family(".bak")
    family("proposals")
    result = resolve("260930-01-client")
    assert_equal "docs/proposals/requirements/260930-01-client.md", result.fetch("requirements_file")
  end

  def test_explicit_archive_path_keeps_its_own_plan_family
    family(".bak")
    family("proposals")
    result = resolve("docs/.bak/requirements/260930-01-client.md")
    assert_equal "docs/.bak/plans/260930-01b-client.md", result.fetch("final_plan")
  end

  def test_empty_checkout_exits_with_a_useful_error
    _, stderr, status = Open3.capture3("ruby", SCRIPT, "260930-01-client", chdir: @root)
    assert_equal 1, status.exitstatus
    assert_includes stderr, "current proposals or archived requirements"
  end
end
