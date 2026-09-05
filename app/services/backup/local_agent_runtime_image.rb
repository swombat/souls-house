module Backup
  class LocalAgentRuntimeImage

    class BuildError < StandardError; end

    VERSION_PATTERN = /\Achaos-cli\s+(\d+(?:\.\d+)+)\z/

    def self.ensure_current!
      new.ensure_current!
    end

    def initialize(
      image: Agents::Config.default_image,
      runtime_dir: Rails.root.join("agent-runtime"),
      production_version: nil,
      desired_chaos_ref: nil,
      capture3: Open3.method(:capture3),
      system: Kernel.method(:system),
      docker_guard: Agents::DockerLocalGuard.method(:check!)
    )
      @docker_guard = docker_guard
      @image = image
      @runtime_dir = runtime_dir
      @production_version = production_version || method(:latest_recorded_chaos_version)
      @desired_chaos_ref = desired_chaos_ref || method(:latest_chaos_ref)
      @capture3 = capture3
      @system = system
    end

    def ensure_current!
      @docker_guard.call
      expected_version = production_version.call
      expected_ref = desired_chaos_ref.call
      current_version = local_version
      current_ref = local_chaos_ref

      if current_version.present? && current_ref != expected_ref
        reason = if current_ref.present?
          "its Chaos ref #{current_ref} does not match latest master #{expected_ref}"
        else
          "it has no Chaos ref provenance"
        end
        puts "Rebuilding #{image} because #{reason}..."
        return build_and_verify!(expected_version, expected_ref)
      end

      if current_version.present? && expected_version.blank?
        puts "Could not determine the production Chaos version; keeping local runtime #{current_version}."
        return false
      end

      if current_version.present? && version_at_least?(current_version, expected_version)
        comparison = current_version == expected_version ? "matches" : "is newer than"
        puts "Local agent runtime #{current_version} #{comparison} production #{expected_version}."
        return false
      end

      reason = current_version.present? ? "#{current_version} is older than production #{expected_version}" : "the image is missing"
      puts "Rebuilding #{image} because #{reason}..."
      build_and_verify!(expected_version, expected_ref)
    end

    private

    attr_reader :image, :runtime_dir, :production_version, :desired_chaos_ref, :capture3, :system

    def build_and_verify!(expected_version, expected_ref)
      build!(expected_ref)
      rebuilt_version = local_version
      raise BuildError, "Built #{image}, but could not read its Chaos version" if rebuilt_version.blank?
      if expected_version.present? && !version_at_least?(rebuilt_version, expected_version)
        raise BuildError, "Built #{image} with #{rebuilt_version}, older than production #{expected_version}"
      end
      rebuilt_ref = local_chaos_ref
      unless rebuilt_ref == expected_ref
        raise BuildError, "Built #{image} with Chaos ref #{rebuilt_ref.presence || 'unknown'}, expected #{expected_ref}"
      end

      puts "Built #{image} with #{rebuilt_version}."
      true
    end

    def latest_recorded_chaos_version
      AgentRuntimeInteraction
        .where.not(chaos_version: [ nil, "" ])
        .order(finished_at: :desc, id: :desc)
        .pick(:chaos_version)
    end

    def local_version
      stdout, _stderr, status = capture3.call(
        "docker", "run", "--rm", "--entrypoint", "chaos", image, "--version"
      )
      status.success? ? stdout.strip.presence : nil
    end

    def local_chaos_ref
      stdout, _stderr, status = capture3.call(
        "docker", "image", "inspect",
        "--format", '{{ index .Config.Labels "house.souls.chaos-ref" }}',
        image
      )
      status.success? ? stdout.strip.presence : nil
    end

    def latest_chaos_ref
      stdout, stderr, status = capture3.call(
        "git", "ls-remote", "https://github.com/seuros/chaos.git", "refs/heads/master"
      )
      ref = stdout.split.first
      return ref if status.success? && ref&.match?(/\A[0-9a-f]{40}\z/)

      raise BuildError, "Could not resolve latest Chaos master: #{stderr.to_s.strip.presence || 'unknown error'}"
    end

    def version_at_least?(candidate, expected)
      return true if expected.blank?
      return candidate == expected unless candidate.match?(VERSION_PATTERN) && expected.match?(VERSION_PATTERN)

      Gem::Version.new(candidate.match(VERSION_PATTERN)[1]) >=
        Gem::Version.new(expected.match(VERSION_PATTERN)[1])
    end

    def build!(chaos_head)
      success = system.call(
        "docker", "build",
        "--build-arg", "CHAOS_HEAD=#{chaos_head}",
        "-t", image,
        runtime_dir.to_s
      )
      raise BuildError, "Could not build #{image}" unless success
    end

  end
end
