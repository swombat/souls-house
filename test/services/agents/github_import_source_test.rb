require "test_helper"
require_relative "../../support/github_import_fixtures"

class Agents::GithubImportSourceTest < ActiveSupport::TestCase

  include GithubImportFixtures

  setup do
    @tmp = Dir.mktmpdir("synthetic-github-")
    @repo = File.join(@tmp, "source")
    FileUtils.mkdir_p(File.join(@repo, ".chaos"))
    manifest = { format: "souls-home/v1", profile: "portable_v1", identity_id: "synthetic-portable-home",
      graph: "external", instructions: "instructions.md", soul: "soul.md", narrative: "narrative.md",
      journal_reader: "reader.py", sync: "sync.py", hooks: ".chaos/hooks.json" }
    %w[instructions.md soul.md narrative.md].each { |file| File.write(File.join(@repo, file), "Synthetic private home") }
    %w[reader.py sync.py].each { |file| File.write(File.join(@repo, file), "raise RuntimeError('MUST NOT EXECUTE')\n") }
    File.write(File.join(@repo, "resident-home.json"), JSON.generate(manifest))
    File.write(File.join(@repo, ".chaos/hooks.json"), JSON.generate(hooks: %w[SessionStart BeforeTurn Stop].index_with {
      [ { hooks: [ { type: "command", command: "false" } ] } ]
    }))
    @git_env = { "PATH" => ENV.fetch("PATH"), "HOME" => @tmp, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL }
    git("init", "--template=", "-b", "main")
    git("config", "user.name", "Synthetic")
    git("config", "user.email", "synthetic@example.invalid")
    git("add", ".")
    git("commit", "-m", "Synthetic identity")
    @sha = git("rev-parse", "HEAD").strip
  end

  teardown { FileUtils.remove_entry(@tmp) }

  test "data-only fetch preserves Git branch origin and tracking without running home code" do
    connection = import_connection
    source = local_source(connection)
    source.with_checkout(branch: "main", commit_sha: @sha) do |root, manifest, sha, branch|
      assert_equal @sha, sha
      assert_equal "main", branch
      assert_equal "synthetic-portable-home", manifest["identity_id"]
      assert File.directory?(File.join(root, ".git"))
      assert_includes File.read(File.join(root, ".git/config")), "refs/heads/main"
      assert_not_includes File.read(File.join(root, ".git/config")), "github_pat"
      assert_equal "main", git_at(root, "branch", "--show-current").strip
      assert_equal @sha, git_at(root, "rev-parse", "origin/main").strip
    end
    assert_includes @commands, [ "remote", "add", "origin", "https://github.com/example/resident.git" ]
    assert @commands.all? { |args| args.none? { |arg| arg.include?("github_pat") } }
  end

  test "rejects links before checkout and does not execute repository scripts" do
    File.symlink("/etc/passwd", File.join(@repo, "escape"))
    git("add", ".")
    git("commit", "-m", "Unsafe link")
    error = assert_raises(Agents::GithubImportSource::Error) { local_source(import_connection).with_checkout(branch: "main") { flunk } }
    assert_match(/Links/, error.message)
    assert @commands.none? { |args| args.first == "checkout" }
  end

  test "rejects classic unknown and branch injection before running Git" do
    %w[ghp_synthetic unknown].each do |token|
      source = Agents::GithubImportSource.new(import_connection(token: token))
      assert_raises(Agents::GithubImportSource::Error) { source.with_checkout(branch: "main") { flunk } }
    end
    source = local_source(import_connection)
    %w[--upload-pack=evil ../../escape main.lock].each do |branch|
      assert_raises(Agents::GithubImportSource::Error) { source.with_checkout(branch: branch) { flunk } }
    end
    assert_empty @commands
  end

  test "standard selection validates data without requiring or executing a repository sync script" do
    path = File.join(@repo, "resident-home.json")
    manifest = JSON.parse(File.read(path))
    manifest.delete("sync")
    manifest["standard_sync"] = { "auto_commit_paths" => [ "journals" ], "append_only_paths" => [ "journals" ] }
    File.write(path, JSON.generate(manifest))
    git("add", "resident-home.json")
    git("commit", "-m", "Standard manifest")
    connection = import_connection
    source = local_source(connection, sync_strategy: "standard")
    source.with_checkout(branch: "main") do |_root, home, _sha, _branch|
      assert_equal [ "journals" ], home.dig("standard_sync", "auto_commit_paths")
    end
    assert_raises(Agents::GithubImportSource::Error) do
      local_source(connection).with_checkout(branch: "main") { flunk }
    end
  end

  test "standard selection refuses unsafe paths on host without running Git sync" do
    path = File.join(@repo, "resident-home.json")
    manifest = JSON.parse(File.read(path))
    manifest["standard_sync"] = { "auto_commit_paths" => [ "." ] }
    File.write(path, JSON.generate(manifest))
    git("add", "resident-home.json")
    git("commit", "-m", "Unsafe config")
    assert_raises(Agents::GithubImportSource::Error) do
      local_source(import_connection, sync_strategy: "standard").with_checkout(branch: "main") { flunk }
    end
  end

  test "host checkout does not execute committed attributes filters or hooks" do
    marker = File.join(@tmp, "MUST-NOT-EXIST")
    File.write(File.join(@repo, ".gitattributes"), "* filter=evil\n")
    FileUtils.mkdir_p(File.join(@repo, "evil-hooks"))
    File.write(File.join(@repo, "evil-hooks/post-checkout"), "#!/bin/sh\ntouch #{marker}\n", perm: 0755)
    git("config", "filter.evil.smudge", "touch #{marker}")
    git("config", "core.hooksPath", "evil-hooks")
    git("add", ".gitattributes", "evil-hooks")
    git("commit", "-m", "Executable config stays at source")
    local_source(import_connection, sync_strategy: "standard").with_checkout(branch: "main") { |_root| }
    assert_not File.exist?(marker)
  end

  private

  def git(*args)
    git_at(@repo, *args)
  end

  def git_at(root, *args)
    out, _err, status = Open3.capture3(@git_env, "git", *args, chdir: root, unsetenv_others: true)
    assert status.success?, "Synthetic Git command failed"
    out
  end

  def local_source(connection, **options)
    source = Agents::GithubImportSource.new(connection, **options)
    real = source.method(:run_git)
    repo = @repo
    @commands = []
    commands = @commands
    source.define_singleton_method(:run_git) do |env, root, *args|
      commands << args.dup
      args[-1] = repo if args.first(3) == [ "remote", "add", "origin" ]
      real.call(env, root, *args)
    end
    source
  end

end
