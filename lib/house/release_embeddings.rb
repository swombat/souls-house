# frozen_string_literal: true

require "open3"
require_relative "env_file"

module House
  # bin/house release-embeddings — builds services/mnemodyne-embeddings for
  # production amd64, publishes it, and records its immutable manifest
  # digest in config/house.env. See docs/mnemodyne-deployment.md.
  class ReleaseEmbeddings
    def initialize(root:, env: ENV, dry_run: false, out: $stdout)
      @root = root
      @env = env
      @dry_run = dry_run
      @out = out
    end

    # Returns true on success (or on a --dry-run print), false if the
    # published digest didn't look right. Raises if HOUSE_EMBEDDINGS_IMAGE
    # is unset, or if build/push fails.
    def run
      image = require_env("HOUSE_EMBEDDINGS_IMAGE")
      ref = "#{image}:#{git_short_sha}"
      context = File.join(@root, "services/mnemodyne-embeddings")

      build_cmd = ["docker", "build", "--platform", "linux/amd64", "-t", ref, context]
      push_cmd = ["docker", "push", ref]
      # `docker buildx imagetools inspect` reads the registry's manifest
      # directly, so this is the *published* manifest digest
      # docs/mnemodyne-deployment.md requires — not a local image ID, which
      # `docker inspect`/RepoDigests would give and which only matches the
      # registry once the push above has actually landed.
      inspect_cmd = ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .Manifest.Digest}}"]

      if @dry_run
        [build_cmd, push_cmd, inspect_cmd].each { |cmd| @out.puts cmd.join(" ") }
        return true
      end

      run!(build_cmd)
      run!(push_cmd)
      digest = capture!(inspect_cmd).strip.delete_prefix('"').delete_suffix('"')

      unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        @out.puts "Unexpected digest output from `#{inspect_cmd.join(' ')}`: #{digest.inspect}"
        return false
      end

      House::EnvFile.replace_value(house_env_path, "HOUSE_EMBEDDINGS_DIGEST", digest)
      @out.puts "HOUSE_EMBEDDINGS_DIGEST=#{digest}"
      @out.puts "Next: bin/kamal accessory boot embeddings (first release) " \
        "or bin/kamal accessory reboot embeddings (redeploying an existing one)."
      true
    end

    private

    def house_env_path
      File.join(@root, "config/house.env")
    end

    def require_env(key)
      value = @env[key].to_s.strip
      return value unless value.empty?

      raise "#{key} is not set — see config/house.env.example"
    end

    # Falls back to "local" outside a git checkout (a temp dir in tests)
    # rather than raising: only the real, non-dry-run build path needs a
    # real tag.
    def git_short_sha
      output, status = Open3.capture2e("git", "-C", @root, "rev-parse", "--short", "HEAD")
      status.success? ? output.strip : "local"
    end

    def run!(cmd)
      @out.puts cmd.join(" ")
      system(*cmd, exception: true)
    end

    def capture!(cmd)
      output, status = Open3.capture2e(*cmd)
      raise "#{cmd.join(' ')} failed:\n#{output}" unless status.success?

      output
    end
  end
end
