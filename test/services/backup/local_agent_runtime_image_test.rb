require "test_helper"

class Backup::LocalAgentRuntimeImageTest < ActiveSupport::TestCase

  test "keeps a local image matching the latest recorded production version" do
    builds = []
    service = build_service(
      production_version: "chaos-cli 47.0.0.200",
      local_versions: [ "chaos-cli 47.0.0.200" ],
      local_refs: [ desired_ref ],
      builds: builds
    )

    assert_equal false, service.ensure_current!
    assert_empty builds
  end

  test "keeps a local image newer than the latest recorded production version" do
    builds = []
    service = build_service(
      production_version: "chaos-cli 47.0.0.200",
      local_versions: [ "chaos-cli 47.0.0.201" ],
      local_refs: [ desired_ref ],
      builds: builds
    )

    assert_equal false, service.ensure_current!
    assert_empty builds
  end

  test "rebuilds an older local image and verifies the result" do
    builds = []
    service = build_service(
      production_version: "chaos-cli 47.0.0.200",
      local_versions: [ "chaos-cli 47.0.0.100", "chaos-cli 47.0.0.200" ],
      local_refs: [ desired_ref, desired_ref ],
      builds: builds
    )

    assert_equal true, service.ensure_current!
    assert_equal [
      [
        "docker", "build",
        "--build-arg", "CHAOS_HEAD=#{desired_ref}",
        "-t", "helixkit-agent-runtime:local",
        "/tmp/agent-runtime"
      ]
    ], builds
  end

  test "rebuilds a missing local image" do
    builds = []
    service = build_service(
      production_version: "chaos-cli 47.0.0.200",
      local_versions: [ nil, "chaos-cli 47.0.0.200" ],
      local_refs: [ nil, desired_ref ],
      builds: builds
    )

    assert_equal true, service.ensure_current!
    assert_equal 1, builds.length
  end

  test "fails when the rebuilt image is still older than production" do
    service = build_service(
      production_version: "chaos-cli 47.0.0.200",
      local_versions: [ "chaos-cli 47.0.0.100", "chaos-cli 47.0.0.150" ],
      local_refs: [ desired_ref, desired_ref ],
      builds: []
    )

    error = assert_raises(Backup::LocalAgentRuntimeImage::BuildError) do
      service.ensure_current!
    end
    assert_match(/older than production/, error.message)
  end

  test "rebuilds a numerically newer image when its Chaos ref is incompatible" do
    builds = []
    service = build_service(
      production_version: "chaos-cli 47.0.0.200",
      local_versions: [ "chaos-cli 47.0.0.300", "chaos-cli 47.0.0.400" ],
      local_refs: [ "b" * 40, desired_ref ],
      builds: builds
    )

    assert_equal true, service.ensure_current!
    assert_equal 1, builds.length
  end

  private

  def desired_ref
    "a" * 40
  end

  def build_service(production_version:, local_versions:, local_refs:, builds:)
    versions = local_versions.dup
    refs = local_refs.dup
    successful_status = Object.new
    successful_status.define_singleton_method(:success?) { true }
    missing_status = Object.new
    missing_status.define_singleton_method(:success?) { false }

    capture3 = lambda do |*command|
      if command.include?("--entrypoint")
        version = versions.shift
        [ version.to_s, "", version ? successful_status : missing_status ]
      else
        assert_equal(
          [
            "docker", "image", "inspect",
            "--format", '{{ index .Config.Labels "house.souls.chaos-ref" }}',
            "helixkit-agent-runtime:local"
          ],
          command
        )
        ref = refs.shift
        [ ref.to_s, "", ref ? successful_status : missing_status ]
      end
    end
    system = lambda do |*command|
      builds << command
      true
    end

    Backup::LocalAgentRuntimeImage.new(docker_guard: -> { true },
      image: "helixkit-agent-runtime:local",
      runtime_dir: Pathname("/tmp/agent-runtime"),
      production_version: -> { production_version },
      desired_chaos_ref: -> { desired_ref },
      capture3: capture3,
      system: system
    )
  end

end
