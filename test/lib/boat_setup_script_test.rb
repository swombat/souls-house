require "test_helper"
require "open3"

class BoatSetupScriptTest < ActiveSupport::TestCase

  setup do
    placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "boat", state: "pending")
    operation = BoatProcurementOperation.create!(agent_placement: placement, requested_by: users(:site_admin_user),
      public_id: "bpo-test", provider_name: "souls-house-bpo-test", approval_reference: "test", sandbox_size: "small",
      state: "create_in_flight")
    @enrollment, @token = RunnerEnrollment.mint!(placement:, boat_operation_id: operation.id)
  end

  def render(**overrides)
    BoatSetupScript.render(enrollment: @enrollment, token: @token, rails_url: "https://souls.example", **overrides)
  end

  # Every file the script installs, decoded from its base64 heredocs.
  def installed_files(script)
    script.scan(/^put (\S+) (\d{4}) <<'B64'\n(.*?)^B64$/m).to_h do |path, mode, body|
      [ path, [ mode, Base64.decode64(body) ] ]
    end
  end

  test "is a bash script within Boat's setupScript limit that bash accepts" do
    script = render
    assert script.start_with?("#!/bin/bash\n")
    assert_operator script.bytesize, :<, BoatSetupScript::LIMIT
    _out, error, status = Open3.capture3("bash", "-n", stdin_data: script)
    assert status.success?, error
  end

  test "installs the same runner config, fetch script and units as the Hetzner cloud-init" do
    files = installed_files(render)
    config = JSON.parse(files.fetch("/etc/souls-house-runner/config.json").last)
    assert_equal "0600", files.fetch("/etc/souls-house-runner/config.json").first
    assert_equal %w[birth_bundle_sha256 enrollment_token rails_url runner_id], config.keys.sort
    assert_equal @token, config["enrollment_token"]
    assert_equal @enrollment.public_id, config["runner_id"]
    assert_equal RunnerUserData::SYSTEMD_UNIT, files.fetch("/etc/systemd/system/souls-house-runner.service").last
    assert_equal RunnerUserData::FETCH_UNIT, files.fetch("/etc/systemd/system/souls-house-runner-fetch.service").last
    assert_equal "0700", files.fetch(RunnerUserData::FETCH_SCRIPT).first
    assert_equal true, JSON.parse(installed_files(render(commands_enabled: true))
      .fetch("/etc/souls-house-runner/config.json").last)["commands_enabled"]
  end

  test "the token appears only inside the encoded config, and nothing is echoed from it" do
    script = render
    assert_not_includes script, @token
    secrets = [ Rails.application.secret_key_base, Rails.application.credentials.dig(:boat, :api_token) ].compact
    secrets.each { |secret| assert_not_includes script, secret }
    assert_no_match(/set -x|cat .*config\.json/, script)
  end

  test "without a well-formed BOAT_ID it stops before installing anything" do
    script = render
    [ nil, "", "not-a-sandbox-id", "bx_0000000l" ].each do |boat_id|
      env = { "PATH" => "/usr/bin:/bin" }
      env["BOAT_ID"] = boat_id unless boat_id.nil?
      # The guard runs first, so sudo is never reached on this test host.
      _out, error, status = Open3.capture3(env, "bash", "-s", stdin_data: script, unsetenv_others: true)
      assert_equal 3, status.exitstatus, boat_id.inspect
      assert_includes error, "BOAT_ID is missing or malformed"
    end
  end

  test "writes the sandbox id where the runner reads it" do
    script = render
    assert_includes script, "| base64 | put #{BoatSetupScript::SANDBOX_ID_PATH} 0644"
    runner = Rails.root.join("host-runner/souls_house_runner.py").read
    assert_includes runner, %(BOAT_SANDBOX_ID_PATH = "#{BoatSetupScript::SANDBOX_ID_PATH}")
  end

  test "refuses a non-https origin" do
    assert_raises(ArgumentError) do
      BoatSetupScript.render(enrollment: @enrollment, token: @token, rails_url: "http://souls.example")
    end
  end

end
