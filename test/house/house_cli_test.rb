require "test_helper"
require Rails.root.join("config/house")
require Rails.root.join("lib/house/cli")

# Phase 2 of the forkable-house plan (docs/2026-09-07-forkable-house-plan-from-lume.md):
# bin/house's subcommands (init, doctor, release-embeddings) exercised
# against temp directories — never this checkout's real config/house.env or
# a real host.
class HouseCliTest < ActiveSupport::TestCase

  class StubRunner
    def initialize(output, ok)
      @output = output
      @ok = ok
    end

    def ssh(_script)
      [@output, @ok]
    end
  end

  GOOD_REMOTE_OUTPUT = <<~OUT
    ARCH=x86_64
    RAM_MB=8192
    DISK_FREE_GB=50
    DOCKER=linux/amd64
    SOCK_GID=999
  OUT

  # --- House::Init ---

  test "init --yes writes house.env with every example comment preserved" do
    in_fixture_root do |root|
      out = StringIO.new
      assert House::Init.new(root: root, yes: true, out: out, stdin: StringIO.new).run

      written = File.read(File.join(root, "config/house.env"))
      example = File.read(File.join(root, "config/house.env.example"))

      example.each_line do |line|
        assert_includes written, line if line.strip.start_with?("#")
      end
      assert_includes written, "HOUSE_DOMAIN=house.example.org"
    end
  end

  test "init refuses to overwrite an existing house.env without --force" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      first_write = File.read(File.join(root, "config/house.env"))

      out = StringIO.new
      result = House::Init.new(root: root, yes: true, out: out, stdin: StringIO.new).run

      assert_equal false, result
      assert_includes out.string, "already exists"
      assert_equal first_write, File.read(File.join(root, "config/house.env"))
    end
  end

  test "init --force overwrites an existing house.env" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      assert House::Init.new(root: root, yes: true, force: true, out: StringIO.new, stdin: StringIO.new).run
    end
  end

  test "init --from is non-interactive: unmentioned keys keep their default, not a prompt" do
    in_fixture_root do |root|
      answers_path = File.join(root, "answers.env")
      File.write(answers_path, "HOUSE_DOMAIN=house.mine.example\nHOUSE_HOST=198.51.100.5\n")

      # No stdin content at all — if init tried to prompt for any other key
      # this would raise/hang instead of returning cleanly.
      out = StringIO.new
      assert House::Init.new(root: root, from: answers_path, out: out, stdin: StringIO.new).run

      env = House.parse(File.read(File.join(root, "config/house.env")))
      assert_equal "house.mine.example", env["HOUSE_DOMAIN"]
      assert_equal "198.51.100.5", env["HOUSE_HOST"]
      assert_equal "s3", env["HOUSE_STORAGE"] # untouched default from the example
    end
  end

  test "init rejects a malformed HOUSE_EMBEDDINGS_DIGEST and writes nothing" do
    in_fixture_root do |root|
      answers_path = File.join(root, "answers.env")
      File.write(answers_path, "HOUSE_EMBEDDINGS_DIGEST=not-a-digest\n")

      error = assert_raises(SystemExit) do
        House::Init.new(root: root, from: answers_path, out: StringIO.new, stdin: StringIO.new).run
      end
      assert_not_equal 0, error.status
      assert_not File.exist?(File.join(root, "config/house.env"))
    end
  end

  test "init rejects an invalid HOUSE_STORAGE value" do
    in_fixture_root do |root|
      answers_path = File.join(root, "answers.env")
      File.write(answers_path, "HOUSE_STORAGE=bogus\n")

      assert_raises(SystemExit) do
        House::Init.new(root: root, from: answers_path, out: StringIO.new, stdin: StringIO.new).run
      end
    end
  end

  # --- House::Doctor ---

  test "doctor passes every check against a healthy stubbed host" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      env = House.parse(File.read(File.join(root, "config/house.env")))
      env["HOUSE_DOCKER_GID"] = "999"
      env["HOUSE_EMBEDDINGS_DIGEST"] = "sha256:#{'a' * 64}"
      # DNS actually has to resolve for a PASS/WARN here; point domain and
      # host at loopback rather than the example's non-resolving defaults.
      env["HOUSE_DOMAIN"] = "localhost"
      env["HOUSE_HOST"] = "127.0.0.1"
      write_secret_files(root)

      out = StringIO.new
      status = House::Doctor.new(
        root: root, env: env, runner: StubRunner.new(GOOD_REMOTE_OUTPUT, true), out: out, stdin: StringIO.new
      ).run

      assert_equal 0, status
      assert_no_match(/^FAIL/, out.string)
    end
  end

  test "doctor fails when HOUSE_DOCKER_GID doesn't match the host" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      env = House.parse(File.read(File.join(root, "config/house.env")))
      env["HOUSE_DOCKER_GID"] = "1"
      write_secret_files(root)

      out = StringIO.new
      status = House::Doctor.new(
        root: root, env: env, runner: StubRunner.new(GOOD_REMOTE_OUTPUT, true), out: out, stdin: StringIO.new
      ).run

      assert_equal 1, status
      assert_match(/FAIL\tHOUSE_DOCKER_GID mismatch — configured 1, host reports 999/, out.string)
    end
  end

  test "doctor offers to fill in a blank HOUSE_DOCKER_GID and writes it on confirmation" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      env = House.parse(File.read(File.join(root, "config/house.env")))
      env["HOUSE_DOCKER_GID"] = ""
      write_secret_files(root)

      out = StringIO.new
      status = House::Doctor.new(
        root: root, env: env, runner: StubRunner.new(GOOD_REMOTE_OUTPUT, true), out: out, stdin: StringIO.new("y\n")
      ).run

      assert_match(/PASS\tHOUSE_DOCKER_GID — written as 999/, out.string)
      house_env = House.parse(File.read(File.join(root, "config/house.env")))
      assert_equal "999", house_env["HOUSE_DOCKER_GID"]
      assert_equal 1, status # RAILS_MASTER_KEY etc. still missing in this fixture beyond write_secret_files' set
    end
  end

  test "doctor fails a required key that's missing" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      env = House.parse(File.read(File.join(root, "config/house.env")))
      env.delete("HOUSE_DOMAIN")

      out = StringIO.new
      House::Doctor.new(
        root: root, env: env, runner: StubRunner.new(GOOD_REMOTE_OUTPUT, true), out: out, stdin: StringIO.new
      ).run

      assert_match(/FAIL\tRequired HOUSE_\* keys present — missing HOUSE_DOMAIN/, out.string)
    end
  end

  test "doctor reports a failed SSH connection without crashing" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      env = House.parse(File.read(File.join(root, "config/house.env")))

      out = StringIO.new
      status = House::Doctor.new(
        root: root, env: env, runner: StubRunner.new("Permission denied (publickey)", false), out: out, stdin: StringIO.new
      ).run

      assert_equal 1, status
      assert_match(/FAIL\tSSH to HOUSE_HOST — Permission denied/, out.string)
    end
  end

  # --- House::ReleaseEmbeddings ---

  test "release-embeddings --dry-run prints the build/push/inspect commands and touches nothing" do
    in_fixture_root do |root|
      House::Init.new(root: root, yes: true, out: StringIO.new, stdin: StringIO.new).run
      before = File.read(File.join(root, "config/house.env"))
      env = House.parse(before)

      out = StringIO.new
      assert House::ReleaseEmbeddings.new(root: root, env: env, dry_run: true, out: out).run

      assert_includes out.string, "docker build --platform linux/amd64"
      assert_includes out.string, "docker push"
      assert_includes out.string, "docker buildx imagetools inspect"
      assert_equal before, File.read(File.join(root, "config/house.env"))
    end
  end

  test "release-embeddings raises without HOUSE_EMBEDDINGS_IMAGE set" do
    in_fixture_root do |root|
      error = assert_raises(RuntimeError) do
        House::ReleaseEmbeddings.new(root: root, env: {}, dry_run: true, out: StringIO.new).run
      end
      assert_includes error.message, "HOUSE_EMBEDDINGS_IMAGE"
    end
  end

  # --- House::EnvFile digest replacement ---

  test "EnvFile.replace_value rewrites only the target line" do
    in_fixture_root do |root|
      path = File.join(root, "config/house.env.example")
      original = File.read(path)

      House::EnvFile.replace_value(path, "HOUSE_EMBEDDINGS_DIGEST", "sha256:#{'b' * 64}")

      rewritten = File.read(path)
      assert_includes rewritten, "HOUSE_EMBEDDINGS_DIGEST=sha256:#{'b' * 64}"
      # every other line is untouched
      (original.lines - ["HOUSE_EMBEDDINGS_DIGEST=\n"]).each do |line|
        assert_includes rewritten, line
      end
    end
  end

  private

  # A temp copy of this checkout's config/house.env.example, in a
  # config/ + services/mnemodyne-embeddings/ layout, so House::Init and
  # House::Doctor see the same structure they'd see for real — without ever
  # touching this checkout's real config/house.env.
  def in_fixture_root
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config/credentials/deployment"))
      FileUtils.mkdir_p(File.join(root, "services/mnemodyne-embeddings"))
      FileUtils.cp(
        Rails.root.join("config/house.env.example"),
        File.join(root, "config/house.env.example")
      )
      yield root
    end
  end

  def write_secret_files(root)
    File.write(File.join(root, "config/credentials/production.key"), "k" * 32)
    File.write(File.join(root, "config/credentials/deployment/kamal_password.key"), "p")
    File.write(File.join(root, "config/credentials/deployment/postgres_pw_prod.key"), "p")
    File.write(File.join(root, "config/credentials/deployment/mnemodyne_embedding_token.key"), "t" * 24)
  end

end
