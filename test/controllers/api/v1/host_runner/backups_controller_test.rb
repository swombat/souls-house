require "test_helper"
require "aws-sdk-s3"
require_relative "../../../../support/runner_signing"

class Api::V1::HostRunner::BackupsControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  ID = "a" * 64
  BASE = "/api/v1/host_runner/backup"
  AGENT_UUID = "11111111-1111-4111-8111-111111111111"
  OTHER_UUID = "22222222-2222-4222-8222-222222222222"

  setup do
    agents(:research_assistant).update!(uuid: AGENT_UUID)
    agents(:code_reviewer).update!(uuid: OTHER_UUID)
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
    @enrollment.enroll!(token:, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    @requested_agents = []
    @client = Aws::S3::Client.new(region: "us-east-1", stub_responses: true)
    @client.stub_responses(:head_object, "NotFound")
    @client.stub_responses(:list_objects_v2, { contents: [], is_truncated: false })
    @client.stub_responses(:put_object, {})
    @client.stub_responses(:delete_object, {})
    Api::V1::HostRunner::BackupsController.repository_factory = lambda do |agent|
      @requested_agents << agent.uuid
      Backup::VmRepository.new(agent:, client: @client, bucket: "synthetic-backups")
    end
  end

  teardown do
    Api::V1::HostRunner::BackupsController.repository_factory = Api::V1::HostRunner::BackupsController::REPOSITORY_FACTORY
  end

  def backup_command(deliver: true)
    command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "backup_resident", payload: {})
    command.deliver!(now: Time.current) if deliver
    command
  end

  def fetch(path, method: "GET", body: "", key: @key, runner_id: @enrollment.public_id, signed_path: path, headers: {}, nonce: SecureRandom.hex(16))
    signed = signed_runner_headers(key, path: signed_path, body:, runner_id:, method:, nonce:)
    process method.downcase.to_sym, path, params: method == "GET" && body.empty? ? nil : body,
      headers: signed.merge("CONTENT_TYPE" => "application/octet-stream").merge(headers)
  end

  test "init signs its query and creates nothing" do
    backup_command
    fetch("#{BASE}/?create=true", method: "POST", signed_path: "#{BASE}/")
    assert_response :unauthorized
    assert_empty @client.api_requests
    fetch("#{BASE}/?create=true", method: "POST")
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_empty @client.api_requests
  end

  test "unknown and ambiguous queries and destructive methods spend no nonce" do
    backup_command
    [
      [ "POST", "#{BASE}/?create=true&extra=1" ],
      [ "POST", "#{BASE}/?create=true&create=true" ],
      [ "POST", "#{BASE}/?create=%74rue" ],
      [ "GET", "#{BASE}/config?create=true" ],
      [ "DELETE", "#{BASE}/config" ],
      [ "DELETE", "#{BASE}/snapshots/#{ID}" ],
      [ "GET", "#{BASE}/data/aa/#{ID}" ]
    ].each do |method, path|
      assert_no_difference -> { RunnerRequestNonce.count } do
        fetch(path, method:)
      end
      assert_response :bad_request
    end
    assert_empty @client.api_requests
  end

  test "pack bodies beyond the ordinary signature cap are accepted and scoped to the enrolled agent" do
    backup_command
    body = "\x00\xff".b * 1.megabyte
    fetch("#{BASE}/data/#{ID}", method: "POST", body:)
    assert_response :ok
    put = @client.api_requests.find { |request| request[:operation_name] == :put_object }[:params]
    assert_equal body, put[:body]
    assert_equal "*", put[:if_none_match]
    assert_equal "agents/11111111-1111-4111-8111-111111111111/data/aa/#{ID}", put[:key]
    assert_equal [ AGENT_UUID ], @requested_agents
  end

  test "32 MiB is accepted and one byte beyond the cap is refused before S3" do
    backup_command
    body = "x" * Backup::VmRepository::MAX_BYTES
    fetch("#{BASE}/data/#{ID}", method: "POST", body:)
    assert_response :ok
    @client.api_requests.clear
    assert_no_difference -> { RunnerRequestNonce.count } do
      fetch("#{BASE}/data/#{ID}", method: "POST", body: body + "x")
    end
    assert_response :content_too_large
    assert_empty @client.api_requests
  end

  test "reader enforces the cap even without Content-Length" do
    controller = Api::V1::HostRunner::BackupsController.new
    controller.set_request!(ActionDispatch::Request.new(
      "rack.input" => StringIO.new("x" * (Backup::VmRepository::MAX_BYTES + 1)),
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "#{BASE}/config"
    ))
    error = assert_raises(Backup::VmRepository::Refused) { controller.send(:backup_body) }
    assert_equal :backup_object_too_large, error.code
  end

  test "listings negotiate v1 names or v2 names and sizes" do
    backup_command
    @client.stub_responses(:list_objects_v2, {
      contents: [ { key: "agents/11111111-1111-4111-8111-111111111111/snapshots/#{ID}", size: 123 } ], is_truncated: false
    })
    fetch("#{BASE}/snapshots/")
    assert_response :ok
    assert_equal [ ID ], response.parsed_body
    fetch("#{BASE}/snapshots/", headers: { "Accept" => Backup::VmRepository::V2_MEDIA_TYPE })
    assert_response :ok
    # restic compares the whole header byte for byte (rest.go: Header.Get("Content-Type") == ContentTypeV2).
    # media_type strips parameters, so it hid the "; charset=utf-8" Rails appends; the live check caught it.
    assert_equal Backup::VmRepository::V2_MEDIA_TYPE, response.headers["Content-Type"]
    assert_equal [ { "name" => ID, "size" => 123 } ], JSON.parse(response.body)
  end

  test "head get partial get and lock delete implement the REST response contract" do
    backup_command
    @client.stub_responses(:head_object, { content_length: 3 })
    @client.stub_responses(:get_object, { body: "abc", content_length: 3 })
    fetch("#{BASE}/config", method: "HEAD")
    assert_response :ok
    assert_equal "3", response.headers["Content-Length"]
    assert_empty response.body
    fetch("#{BASE}/config")
    assert_response :ok
    assert_equal "abc", response.body
    assert_equal "application/octet-stream", response.media_type
    @client.stub_responses(:get_object, { body: "bc", content_length: 2, content_range: "bytes 1-2/3" })
    fetch("#{BASE}/config", headers: { "Range" => "bytes=1-2" })
    assert_response :partial_content
    assert_equal "bc", response.body
    assert_equal "bytes 1-2/3", response.headers["Content-Range"]
    fetch("#{BASE}/locks/#{ID}", method: "DELETE")
    assert_response :ok
    delete = @client.api_requests.find { |request| request[:operation_name] == :delete_object }
    assert_equal "agents/11111111-1111-4111-8111-111111111111/locks/#{ID}", delete[:params][:key]
  end

  test "queued answered stale generation and absent backup commands do not authorize storage" do
    fetch("#{BASE}/config")
    assert_response :not_found
    command = backup_command(deliver: false)
    fetch("#{BASE}/config")
    assert_response :not_found
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => "done" }, now: Time.current)
    fetch("#{BASE}/config")
    assert_response :not_found
    backup_command
    @placement.update!(generation: @placement.generation + 1)
    fetch("#{BASE}/config")
    assert_response :not_found
    assert_empty @client.api_requests
  end

  test "wrong key revoked retired and nonce replay do not reach storage" do
    backup_command
    assert_no_difference -> { RunnerRequestNonce.count } do
      fetch("#{BASE}/config", key: runner_key)
    end
    assert_response :unauthorized
    @placement.update!(state: "retired")
    fetch("#{BASE}/config")
    assert_response :gone
    @placement.update!(state: "pending")
    @enrollment.revoke!
    fetch("#{BASE}/config")
    assert_response :forbidden
    assert_empty @client.api_requests
    @enrollment.update!(revoked_at: nil)
    nonce = SecureRandom.hex(16)
    fetch("#{BASE}/?create=true", method: "POST", nonce:)
    assert_response :ok
    fetch("#{BASE}/?create=true", method: "POST", nonce:)
    assert_response :unauthorized
  end

  test "a different enrollment cannot use this resident's delivered command" do
    backup_command
    other_placement = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    other, token = RunnerEnrollment.mint!(placement: other_placement)
    other.confirm_provider_server!(5151)
    key = runner_key
    other.enroll!(token:, public_key: public_key_b64(key), reported_server_id: 5151, facts: {}, nonce: SecureRandom.hex(16))
    assert_no_difference -> { RunnerRequestNonce.count } do
      fetch("#{BASE}/config", key:, runner_id: other.public_id)
    end
    assert_response :not_found
    assert_empty @requested_agents
    assert_empty @client.api_requests
  end

  test "non-write bodies are refused and storage exceptions are sanitized" do
    backup_command
    fetch("#{BASE}/?create=true", method: "POST", body: "not empty")
    assert_response :bad_request
    assert_empty @client.api_requests
    @client.stub_responses(:head_object, "AccessDenied")
    fetch("#{BASE}/config")
    assert_response :service_unavailable
    assert_equal({ "error" => "backup_storage_unavailable" }, response.parsed_body)
  end

  test "invalid UUIDs fail closed before S3 even with valid signed authorization" do
    backup_command
    [ nil, "", "../other", "not-a-uuid" ].each do |uuid|
      @placement.agent.update_column(:uuid, uuid)
      fetch("#{BASE}/config", method: "POST", body: "bytes")
      assert_response :service_unavailable
      assert_equal "invalid_backup_identity", response.parsed_body["error"]
      assert_empty @client.api_requests
    end
  end

  test "authentication precedes admission and a busy authenticated retry spends its nonce only once" do
    backup_command
    observer = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
    4.times do |slot|
      key = Backup::VmRepository.lock_key("slot:endpoint:#{slot}")
      observer.exec("SELECT pg_advisory_lock(#{key})")
    end
    assert_no_difference -> { RunnerRequestNonce.count } do
      fetch("#{BASE}/config", key: runner_key)
    end
    assert_response :unauthorized
    nonce = SecureRandom.hex(16)
    assert_difference -> { RunnerRequestNonce.count }, 1 do
      fetch("#{BASE}/config", nonce:)
    end
    assert_response :too_many_requests
    fetch("#{BASE}/config", nonce:)
    assert_response :unauthorized
    assert_empty @client.api_requests
  ensure
    observer&.exec("SELECT pg_advisory_unlock_all()")
    observer&.close
  end

end
