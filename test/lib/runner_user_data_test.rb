require "test_helper"

class RunnerUserDataTest < ActiveSupport::TestCase

  setup do
    placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, @token = RunnerEnrollment.mint!(placement:)
  end

  # The production image is built from an explicit COPY list; a runner left
  # out of it fails every purchase before the create request (2026-10-08).
  test "the production image ships the runner source" do
    dockerfile = Rails.root.join("Dockerfile").read
    assert_includes dockerfile, "COPY host-runner/souls_house_runner.py host-runner/souls_house_runner.py"
    assert_includes dockerfile, "COPY --from=build --chown=rails:rails /rails/host-runner /rails/host-runner"
  end

  def render(**overrides)
    RunnerUserData.render(enrollment: @enrollment, token: @token, rails_url: "https://souls.example", **overrides)
  end

  def parsed
    YAML.safe_load(render)
  end

  test "is a cloud-config document within Hetzner's size limit" do
    assert render.start_with?("#cloud-config\n")
    assert_operator render.bytesize, :<, RunnerUserData::HETZNER_USER_DATA_LIMIT
    assert_equal render, render
  end

  test "the enrollment token is the only secret, and appears once" do
    output = render
    assert_equal 1, output.scan(@token).size
    secrets = [ Rails.application.secret_key_base, Rails.application.credentials.dig(:hetzner, :api_token) ].compact
    secrets.each { |secret| assert_not_includes output, secret }
    config = JSON.parse(parsed["write_files"].find { |f| f["path"] == "/etc/souls-house-runner/config.json" }["content"])
    assert_equal %w[enrollment_token rails_url runner_id], config.keys.sort
    assert_equal "0600", parsed["write_files"].find { |f| f["path"] == "/etc/souls-house-runner/config.json" }["permissions"]
  end

  test "embeds exactly the runner in this repository" do
    runner = parsed["write_files"].find { |f| f["path"] == "/opt/souls-house-runner/souls_house_runner.py" }
    assert_equal "gz+b64", runner["encoding"]
    assert_equal File.read(Rails.root.join("host-runner/souls_house_runner.py")), Zlib.gunzip(Base64.strict_decode64(runner["content"]))
  end

  # Hetzner refuses user_data over 32 KiB, and render raises before any
  # create request. The real runner must fit with room to grow; a runner that
  # outgrew it would make every VM order fail (#238 part 1 nearly did).
  test "the document with the real runner fits Hetzner's limit with margin" do
    assert_operator render.bytesize, :<, RunnerUserData::HETZNER_USER_DATA_LIMIT * 3 / 4
    assert_equal render, render
  end

  test "drops inbound traffic except SSH and starts only the firewall, Docker and the runner" do
    nft = parsed["write_files"].find { |f| f["path"].end_with?(".nft") }["content"]
    assert_includes nft, "policy drop;"
    assert_equal [ "22" ], nft.scan(/tcp dport (\d+)/).flatten
    assert_equal %w[68 546], nft.scan(/udp sport \d+ udp dport (\d+)/).flatten
    assert_equal %w[systemctl mask nftables.service], parsed["runcmd"].first
    enabled = parsed["runcmd"].select { |cmd| cmd[1] == "enable" }.map(&:last)
    assert_equal %w[souls-house-firewall docker souls-house-runner], enabled
  end

  # Debian 13 split the client out of docker.io; without docker-cli the
  # runner reports no docker_version (seen on the first pilot VM, 2026-10-08).
  test "installs the Docker client as well as the daemon" do
    assert_includes parsed["packages"], "docker.io"
    assert_includes parsed["packages"], "docker-cli"
  end

  test "refuses anything but a bare https origin for the house" do
    [ "http://souls.example", "https://user:pw@souls.example", "https://souls.example/api",
      "https://souls.example?x=1", "https://souls.example#f", "https://", "not a url" ].each do |url|
      assert_raises(ArgumentError, url) { render(rails_url: url) }
    end
    assert render(rails_url: "https://souls.example/")
  end

end
