require "tmpdir"
require "json"
require "open3"
require "timeout"

module Agents
  # Git is used as a data transport, never as an installer. No resident/provider
  # environment, global Git config, templates, filters, submodules or hooks.
  class GithubImportSource

    class Error < StandardError; end

    MAX_BYTES = 100.megabytes
    MAX_FILES = 20_000
    BRANCH_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9_./-]{0,199}\z}
    SHA_PATTERN = /\A[0-9a-f]{40}\z/

    def initialize(connection, sync_strategy: "existing")
      @connection = connection
      raise Error, "Invalid sync selection" unless sync_strategy.in?(%w[existing standard])
      @sync_strategy = sync_strategy
    end

    def with_checkout(branch:, commit_sha: nil)
      raise Error, "Only connected fine-grained-format GitHub tokens can onboard identities" unless
        @connection.status == "connected" && token.start_with?("github_pat_")
      repository = @connection.credential_metadata["repository"].to_s
      raise Error, "Invalid GitHub repository" unless repository.match?(Services::GithubTokenAdapter::REPOSITORY_PATTERN)
      branch = branch.presence || @connection.credential_metadata["default_branch"].to_s
      raise Error, "Invalid branch" unless branch.match?(BRANCH_PATTERN) &&
        !branch.include?("..") && !branch.include?("//") && !branch.end_with?("/", ".", ".lock")
      raise Error, "Invalid revision" if commit_sha && !commit_sha.match?(SHA_PATTERN)

      Dir.mktmpdir("github-resident-") do |dir|
        File.chmod(0700, dir)
        root = File.join(dir, "home")
        Dir.mkdir(root, 0700)
        askpass = File.join(dir, "askpass.py")
        secret = File.join(dir, "credential")
        File.write(secret, token, mode: "w", perm: 0600)
        File.write(askpass, <<~PYTHON, mode: "w", perm: 0700)
          #!/usr/bin/env python3
          import sys
          from pathlib import Path
          print("x-access-token" if "Username" in sys.argv[1] else Path(#{secret.to_json}).read_text())
        PYTHON
        env = { "PATH" => ENV.fetch("PATH"), "HOME" => dir, "GIT_CONFIG_NOSYSTEM" => "1",
          "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_TERMINAL_PROMPT" => "0", "GIT_ASKPASS" => askpass }
        run_git(env, root, "init", "--template=")
        run_git(env, root, "remote", "add", "origin", "https://github.com/#{repository}.git")
        run_git(env, root, "fetch", "--depth=1", "--no-tags", "origin", commit_sha || "refs/heads/#{branch}")
        sha = run_git(env, root, "rev-parse", "FETCH_HEAD").strip
        raise Error, "GitHub returned an invalid revision" unless sha.match?(SHA_PATTERN) && (!commit_sha || sha == commit_sha)
        tree = run_git(env, root, "ls-tree", "-r", "-l", "-z", sha)
        entries = tree.split("\0")
        raise Error, "Repository has too many files" if entries.length > MAX_FILES
        total = 0
        entries.each do |entry|
          descriptor, path = entry.split("\t", 2)
          mode, type, _hash, size = descriptor.split
          raise Error, "Links and submodules are not supported" unless type == "blob" && %w[100644 100755].include?(mode)
          Agents::Portability::Archive.safe_path!(path)
          total += Integer(size)
          raise Error, "Repository is too large" if total > MAX_BYTES
        end
        run_git(env, root, "checkout", "-b", branch, sha)
        run_git(env, root, "update-ref", "refs/remotes/origin/#{branch}", sha)
        run_git(env, root, "config", "branch.#{branch}.remote", "origin")
        run_git(env, root, "config", "branch.#{branch}.merge", "refs/heads/#{branch}")
        # Disable Git hooks for checkout and future stock sync. Lifecycle hooks
        # remain explicit, site-approved Chaos definitions.
        run_git(env, root, "config", "core.hooksPath", "/dev/null")
        manifest = validate_home(root)
        yield root, manifest, sha, branch
      end
    rescue Agents::Portability::Error, JSON::ParserError, KeyError, ArgumentError
      raise Error, "Invalid GitHub identity repository"
    end

    private

    def token
      @connection.credential_payload_hash["token"].to_s
    end

    def run_git(env, root, *args)
      output = ""
      Open3.popen3(env, "git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
        *args, chdir: root, unsetenv_others: true, pgroup: true, rlimit_fsize: MAX_BYTES) do |stdin, stdout, stderr, thread|
        stdin.close
        # Bound both captured output and time; do not include Git's diagnostics
        # in user errors (remote output may contain credentials or private data).
        readers = [ Thread.new { stdout.read(MAX_BYTES + 1) }, Thread.new { stderr.read(MAX_BYTES + 1) } ]
        begin
          Timeout.timeout(120) do
            output = readers.first.value.to_s
            readers.last.value
            raise Error, "GitHub fetch or checkout failed" unless thread.value.success?
          end
          raise Error, "Git output exceeds import limit" if output.bytesize > MAX_BYTES
        ensure
          begin
            Process.kill("KILL", -thread.pid) if thread.alive?
          rescue Errno::ESRCH
            nil
          end
          readers.each(&:join)
        end
      end
      output
    rescue Timeout::Error
      raise Error, "GitHub fetch or checkout timed out"
    end

    def validate_home(root)
      path = File.join(root, "resident-home.json")
      raise Error, "Missing or oversized resident-home.json" unless File.file?(path) && File.size(path) <= 64.kilobytes
      manifest = JSON.parse(File.read(path))
      identity = manifest.fetch("identity_id")
      raise Error, "Invalid portable identity ID" unless identity.is_a?(String) && identity.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}\z/)
      env = { "PATH" => ENV.fetch("PATH"), "SOULSHOUSE_HOME_PROFILE" => "portable_v1",
        "SOULSHOUSE_HOME_SYNC_STRATEGY" => @sync_strategy,
        "SOULSHOUSE_HOME_ROOT" => root, "SOULSHOUSE_PORTABLE_HOME_ID" => identity,
        "CHAOS_HOME" => File.join(File.dirname(root), "unused-chaos-home") }
      script = Rails.root.join("agent-runtime/imported_home.py").to_s
      [ [], [ "--hook-import-check" ] ].each do |args|
        _out, _err, status = Open3.capture3(env, "python3", script, *args, unsetenv_others: true)
        raise Error, "Repository must contain a valid portable_v1 home and importable hooks" unless status.success?
      end
      manifest
    end

  end
end
