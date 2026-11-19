require "test_helper"

class Api::V1::Companion::PairingsControllerTest < ActionDispatch::IntegrationTest

  OFFER = [ { volume: "darwin-volume:main", label: "Main disk", access: "read" } ].freeze

  test "a computer opens a pairing without a login, polls, and is refused with a wrong secret" do
    post api_v1_companion_pairings_path, params: { name: "Paulina's Mac", device_request_id: "pair-1", volumes: OFFER },
      as: :json
    assert_response :created
    body = response.parsed_body
    assert_match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/, body["code"])
    assert_equal "no-store", response.headers["Cache-Control"]

    post claim_api_v1_companion_pairing_path(body["id"]), params: { poll_secret: body["poll_secret"] }, as: :json
    assert_response :accepted
    assert_equal "pending", response.parsed_body["status"]

    post claim_api_v1_companion_pairing_path(body["id"]), params: { poll_secret: "shcp_#{'B' * 43}" }, as: :json
    assert_response :not_found

    # The secret counts only in the body, never in the query string.
    post claim_api_v1_companion_pairing_path(body["id"], poll_secret: body["poll_secret"]), as: :json
    assert_response :not_found
  end

  test "bad offers get 422" do
    post api_v1_companion_pairings_path, params: { name: "Mac", device_request_id: "pair-1", volumes: [] }, as: :json
    assert_response :unprocessable_entity
  end

end
