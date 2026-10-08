require "test_helper"
require_relative "../../../../support/runner_signing"

class Api::V1::HostRunner::ImagesControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  IMAGE = "sha256:#{'a' * 64}".freeze
  OTHER = "sha256:#{'b' * 64}".freeze

  setup do
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
    @enrollment.enroll!(token:, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    @served = []
    Api::V1::HostRunner::ImagesController.image_source = lambda do |image_id, &block|
      @served << image_id
      block.call("tar-of-#{image_id}")
    end
  end

  teardown do
    Api::V1::HostRunner::ImagesController.image_source = Api::V1::HostRunner::ImagesController.image_source_default
  end

  def fetch(image_id, key: @key, runner_id: @enrollment.public_id)
    path = "/api/v1/host_runner/images/#{image_id}"
    get path, headers: signed_runner_headers(key, path:, body: "", runner_id:, method: "GET")
  end

  def start_command(image, deliver: true)
    command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: { "image" => image })
    command.deliver!(now: Time.current) if deliver
    command
  end

  test "serves exactly the image a delivered start_resident asked for" do
    start_command(IMAGE)
    fetch(IMAGE)
    assert_response :ok
    assert_equal "tar-of-#{IMAGE}", response.body
    assert_equal [ IMAGE ], @served
  end

  test "an image nobody asked this runner to start is not served, and spends no nonce" do
    start_command(IMAGE)
    assert_no_difference -> { RunnerRequestNonce.count } do
      fetch(OTHER)
    end
    assert_response :not_found
    assert_equal "image_not_requested", response.parsed_body["error"]
    assert_empty @served
  end

  test "a queued, answered, or stale-generation start does not authorise a fetch" do
    queued = start_command(IMAGE, deliver: false)
    fetch(IMAGE)
    assert_response :not_found
    queued.deliver!(now: Time.current)
    queued.record_result!({ "outcome" => "done" }, now: Time.current)
    fetch(IMAGE)
    assert_response :not_found
    start_command(IMAGE)
    @placement.update!(generation: @placement.generation + 1)
    fetch(IMAGE)
    assert_response :not_found
    assert_empty @served
  end

  test "another runner cannot fetch this runner's image" do
    start_command(IMAGE)
    other_placement = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    other, token = RunnerEnrollment.mint!(placement: other_placement)
    other.confirm_provider_server!(5151)
    other_key = runner_key
    other.enroll!(token:, public_key: public_key_b64(other_key), reported_server_id: 5151, facts: {}, nonce: SecureRandom.hex(16))
    fetch(IMAGE, key: other_key, runner_id: other.public_id)
    assert_response :not_found
    fetch(IMAGE, key: runner_key)
    assert_response :unauthorized
    assert_empty @served
  end

  test "revoked and retired are refused before anything is served" do
    start_command(IMAGE)
    @placement.update!(state: "retired")
    fetch(IMAGE)
    assert_response :gone
    @placement.update!(state: "pending")
    @enrollment.revoke!
    fetch(IMAGE)
    assert_response :forbidden
    assert_empty @served
  end

  test "only image IDs route at all" do
    start_command(IMAGE)
    [ "helixkit-agent-runtime:latest", "sha256:abc", "sha256:#{'A' * 64}" ].each do |bad|
      fetch(bad)
      assert_response :not_found, bad
    end
    assert_empty @served
  end

end
