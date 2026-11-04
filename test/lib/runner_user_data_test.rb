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
    assert_includes dockerfile, "COPY host-runner/backup_proxy.py host-runner/backup_proxy.py"
    assert_includes dockerfile, "COPY host-runner/birth_fetch.py host-runner/birth_fetch.py"
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
    assert_equal %w[birth_bundle_sha256 enrollment_token rails_url runner_id], config.keys.sort
    assert_equal "0600", parsed["write_files"].find { |f| f["path"] == "/etc/souls-house-runner/config.json" }["permissions"]
  end

  # #779: the runner is not embedded. The document pins one digest; the
  # house keeps those bytes, so a release between render and fetch serves
  # the same runner.
  test "pins the current runner bundle by digest instead of embedding it" do
    paths = parsed["write_files"].map { |f| f["path"] }
    assert_not paths.any? { |path| path.include?("source.tar") }
    assert_not_includes parsed["packages"], "xz-utils"
    bundle = RunnerBundle.current
    config = JSON.parse(parsed["write_files"].find { |f| f["path"] == "/etc/souls-house-runner/config.json" }["content"])
    assert_equal bundle.sha256, config["birth_bundle_sha256"]
    assert_equal bundle.sha256, @enrollment.reload.birth_bundle_sha256
    assert_equal bundle.bytes, RunnerBirthBundle.find_by!(sha256: bundle.sha256).bytes
    assert_equal 1, render.scan(/\b[0-9a-f]{64}\b/).uniq.size
  end

  test "carries the compacted fetch script, and its unit retries within the birth deadline" do
    script = parsed["write_files"].find { |f| f["path"] == RunnerUserData::FETCH_SCRIPT }
    assert_equal "gz+b64", script["encoding"]
    assert_equal "0700", script["permissions"]
    source = Zlib.gunzip(Base64.strict_decode64(script["content"]))
    assert_equal RunnerUserData.compact_source(File.read(RunnerUserData::FETCH_SOURCE_PATH)), source
    unit = parsed["write_files"].find { |f| f["path"].end_with?("souls-house-runner-fetch.service") }["content"]
    assert_includes unit, "ExecStart=/usr/bin/python3 #{RunnerUserData::FETCH_SCRIPT}"
    assert_includes unit, "Restart=on-failure"
    assert_includes unit, "RestartPreventExitStatus=3"
    assert_includes unit, "StartLimitIntervalSec=0"
    runner = parsed["write_files"].find { |f| f["path"].end_with?("souls-house-runner.service") }["content"]
    assert_includes runner, "ConditionPathExists=/opt/souls-house-runner/current/bundle.sha256"
    assert_not_includes runner, "Requires="
    give_up = source[/GIVE_UP_AFTER = (.+)$/, 1]
    assert_equal RunnerUserData::FETCH_GIVE_UP_AFTER.to_i, eval(give_up) # rubocop:disable Security/Eval
    assert_operator RunnerUserData::FETCH_GIVE_UP_AFTER, :<, Agents::VmBirthPolicy::BIRTH_DEADLINE
    assert_includes parsed["runcmd"], %w[systemctl enable --now --no-block souls-house-runner-fetch]
    assert_includes parsed["runcmd"], %w[systemctl enable souls-house-runner]
  end

  test "a release between render and fetch still serves the pinned bytes" do
    render
    pinned = @enrollment.reload.birth_bundle_sha256
    newer = RunnerBundle::Bundle.new(bytes: "newer".b, sha256: Digest::SHA256.hexdigest("newer"))
    other, _token = RunnerEnrollment.mint!(placement: @enrollment.agent_placement)
    RunnerBirthBundle.pin!(other, bundle: newer)
    assert_equal RunnerBirthBundle.find_by!(sha256: pinned).bytes, @enrollment.authorize_birth_bundle!(token: @token, sha256: pinned)
  end

  test "drops a pinned blob once no unenrolled enrollment pins it" do
    render
    pinned = @enrollment.reload.birth_bundle_sha256
    @enrollment.update!(enrolled_at: Time.current, public_key: Base64.strict_encode64("k" * 32))
    other, _token = RunnerEnrollment.mint!(placement: @enrollment.agent_placement)
    newer = RunnerBundle::Bundle.new(bytes: "newer".b, sha256: Digest::SHA256.hexdigest("newer"))
    RunnerBirthBundle.pin!(other, bundle: newer)
    assert_nil RunnerBirthBundle.find_by(sha256: pinned)
    assert RunnerBirthBundle.find_by(sha256: newer.sha256)
  end

  test "the command channel is on only for a literal true" do
    config = ->(output) { JSON.parse(YAML.safe_load(output.delete_prefix("#cloud-config\n"))["write_files"].find { |f| f["path"] == "/etc/souls-house-runner/config.json" }["content"]) }
    assert_not config.call(render).key?("commands_enabled")
    [ "true", 1, "yes" ].each { |value| assert_not config.call(render(commands_enabled: value)).key?("commands_enabled") }
    assert_equal true, config.call(render(commands_enabled: true))["commands_enabled"]
  end

  # Hetzner refuses user_data over 32 KiB, and render raises before any
  # create request. The real runner must fit with room to grow; a runner that
  # outgrew it would make every VM order fail (#238 part 1 nearly did).
  test "the document with the real runner fits Hetzner's limit with margin" do
    # The runner is fetched by digest at birth (#779), so runner changes no
    # longer weigh here. What remains (config, units, firewall, the fetch
    # script) must stay well inside the limit: an 8 KiB ceiling leaves room
    # for the whole document to quadruple before a VM order fails. Weighed
    # as production renders it: the house's own origin and the command
    # channel on (no runtime_image).
    production = render(rails_url: "https://souls.house", commands_enabled: true)
    assert_operator production.bytesize, :<, 8.kilobytes
    assert_operator render.bytesize, :<=, production.bytesize
    assert_equal production, render(rails_url: "https://souls.house", commands_enabled: true)
  end

  test "drops inbound traffic except SSH and starts only the firewall, Docker and the runner" do
    nft = parsed["write_files"].find { |f| f["path"].end_with?(".nft") }["content"]
    assert_includes nft, "policy drop;"
    assert_equal [ "22" ], nft.scan(/tcp dport (\d+)/).flatten
    assert_equal %w[68 546], nft.scan(/udp sport \d+ udp dport (\d+)/).flatten
    assert_equal %w[systemctl mask nftables.service], parsed["runcmd"].first
    enabled = parsed["runcmd"].select { |cmd| cmd[1] == "enable" }.map(&:last)
    assert_equal %w[souls-house-firewall docker souls-house-runner souls-house-runner-fetch], enabled
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
