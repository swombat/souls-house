require "test_helper"
require_relative "../../../../support/runner_signing"

# #593: the house keeps VM runners current through the command queue.
class Api::V1::HostRunner::RunnerBundlesControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  setup do
    @agent = agents(:research_assistant)
    @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
    @enrollment.enroll!(token:, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    @bundle = RunnerBundle.current
  end

  def fetch(digest)
    path = "/api/v1/host_runner/runner_bundles/#{digest}"
    get path, headers: signed_runner_headers(@key, path:, body: "", runner_id: @enrollment.public_id, method: "GET")
  end

  def beat(facts)
    body = { facts: { provider_server_id: 4242 }.merge(facts) }.to_json
    path = "/api/v1/host_runner/heartbeat"
    post path, params: body, headers: signed_runner_headers(@key, path:, body:, runner_id: @enrollment.public_id)
      .merge("CONTENT_TYPE" => "application/json")
  end

  def updates = @enrollment.commands.where(kind: "update_runner")

  test "the bundle is the deterministic package cloud-init embeds" do
    assert_equal RunnerUserData.compressed_source_bundle, @bundle.bytes
    assert_equal Digest::SHA256.hexdigest(@bundle.bytes), @bundle.sha256
    assert_same @bundle, RunnerBundle.current, "packaged once per source"
  end

  test "a heartbeat from a runner on another bundle queues one update_runner naming the current one" do
    beat("runner_bundle_sha256" => "0" * 64)
    assert_response :ok
    assert_equal 1, updates.count
    payload = JSON.parse(updates.last.payload_json)
    assert_equal({ "sha256" => @bundle.sha256, "bytes" => @bundle.bytes.bytesize }, payload)
    assert_equal "0" * 64, @enrollment.reload.last_facts["runner_bundle_sha256"]

    beat("runner_bundle_sha256" => "0" * 64)
    assert_equal 1, updates.count, "an open update is not queued twice"
  end

  test "a runner on the current bundle is left alone" do
    beat("runner_bundle_sha256" => @bundle.sha256)
    assert_response :ok
    assert_equal 0, updates.count
  end

  test "a runner too old to know the command is asked once, not every heartbeat" do
    beat({})
    command = updates.last
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => "refused", "error" => "command not allowed on this runner: 'update_runner'" },
      now: Time.current)

    travel 2.hours do
      beat({})
    end
    assert_equal 1, updates.count
  end

  test "a failed update is retried after an hour, not before" do
    beat("runner_bundle_sha256" => "0" * 64)
    command = updates.last
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => "failed", "error" => "could not fetch" }, now: Time.current)

    beat("runner_bundle_sha256" => "0" * 64)
    assert_equal 1, updates.count
    travel 61.minutes do
      beat("runner_bundle_sha256" => "0" * 64)
    end
    assert_equal 2, updates.count
  end

  test "a placement that isn't ready gets no update" do
    @placement.update_columns(state: "pending")
    beat("runner_bundle_sha256" => "0" * 64)
    assert_response :ok
    assert_equal 0, updates.count
  end

  test "serves the bundle only while a delivered update_runner names it" do
    fetch(@bundle.sha256)
    assert_response :not_found

    beat("runner_bundle_sha256" => "0" * 64)
    fetch(@bundle.sha256)
    assert_response :not_found, "queued is not delivered"

    updates.last.deliver!(now: Time.current)
    fetch(@bundle.sha256)
    assert_response :ok
    assert_equal @bundle.bytes, response.body.b
    assert_equal "no-store", response.headers["Cache-Control"]

    fetch("1" * 64)
    assert_response :not_found
  end

  test "an unsigned or foreign request gets nothing" do
    beat("runner_bundle_sha256" => "0" * 64)
    updates.last.deliver!(now: Time.current)
    get "/api/v1/host_runner/runner_bundles/#{@bundle.sha256}"
    assert_not_equal 200, response.status
    other = runner_key
    path = "/api/v1/host_runner/runner_bundles/#{@bundle.sha256}"
    get path, headers: signed_runner_headers(other, path:, body: "", runner_id: @enrollment.public_id, method: "GET")
    assert_not_equal 200, response.status
  end

end
