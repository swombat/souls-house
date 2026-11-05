require "test_helper"

# #779: a new VM fetches the runner its user_data pins, authorised by the
# one-time enrollment token, which this read never spends.
class Api::V1::HostRunner::BirthBundlesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, @token = RunnerEnrollment.mint!(placement: @placement)
    @digest = RunnerBirthBundle.pin!(@enrollment)
    @bytes = RunnerBirthBundle.find_by!(sha256: @digest).bytes
  end

  def fetch(digest = @digest, token: @token, runner_id: @enrollment.public_id)
    headers = { "X-Runner-Id" => runner_id }
    headers["Authorization"] = "Bearer #{token}" if token
    get "/api/v1/host_runner/birth_bundles/#{digest}", headers:
  end

  test "serves exactly the pinned bytes and leaves the token unspent" do
    fetch
    assert_response :ok
    assert_equal @bytes, response.body
    assert_equal "no-store", response.headers["Cache-Control"]
    @enrollment.reload
    assert_nil @enrollment.enrolled_at
    assert_equal 1, @enrollment.birth_bundle_fetches
    assert_equal 0, @enrollment.request_nonces.count
    @enrollment.authenticate_token!(@token)
  end

  test "another digest answers 404, including another enrollment's" do
    other, _token = RunnerEnrollment.mint!(placement: @placement)
    newer = RunnerBundle::Bundle.new(bytes: "newer".b, sha256: Digest::SHA256.hexdigest("newer"))
    RunnerBirthBundle.pin!(other, bundle: newer)
    fetch(newer.sha256)
    assert_response :not_found
    fetch("0" * 64)
    assert_response :not_found
  end

  test "refuses a missing or wrong token" do
    fetch(token: nil)
    assert_response :unauthorized
    fetch(token: "wrong")
    assert_response :unauthorized
    get "/api/v1/host_runner/birth_bundles/#{@digest}",
      headers: { "X-Runner-Id" => @enrollment.public_id, "Authorization" => "Basic #{@token}" }
    assert_response :unauthorized
    fetch(runner_id: "rnr_unknown")
    assert_response :unauthorized
  end

  test "refuses once enrolled, expired, revoked or retired" do
    @enrollment.update!(enrolled_at: Time.current, public_key: Base64.strict_encode64("k" * 32))
    fetch
    assert_response :conflict
    @enrollment.update!(enrolled_at: nil, public_key: nil, expires_at: 1.minute.ago)
    fetch
    assert_response :gone
    @enrollment.update!(expires_at: 1.hour.from_now, revoked_at: Time.current)
    fetch
    assert_response :forbidden
    @enrollment.update!(revoked_at: nil)
    @placement.update_columns(state: "retired")
    fetch
    assert_response :gone
    assert_equal 0, @enrollment.reload.birth_bundle_fetches
  end

  test "caps birth fetches per enrollment, durably" do
    @enrollment.update_columns(birth_bundle_fetches: RunnerEnrollment::MAX_BIRTH_FETCHES - 1)
    fetch
    assert_response :ok
    fetch
    assert_response :too_many_requests
    assert_equal RunnerEnrollment::MAX_BIRTH_FETCHES, @enrollment.reload.birth_bundle_fetches
  end

  test "never writes the token to the log" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    original = Rails.logger
    Rails.logger = logger
    ActionController::Base.logger = logger
    fetch(token: "wrong")
    fetch
  ensure
    Rails.logger = original
    ActionController::Base.logger = original
    assert_not_includes io.string, @token
  end

end
