require "test_helper"

class Api::V1::RhythmsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @resident = agents(:research_assistant)
    @creator = users(:user_1)
    @rhythm = Rhythm.create!(
      account: @resident.account, creator: @creator, agents: [ @resident ],
      title: "Return", opening: "What is worth noticing?", cadence: "daily",
      time_of_day: "09:00", timezone: "UTC"
    )
    key = ApiKey.generate_for(@creator, name: "Rhythm tests", agent: @resident)
    @headers = { "Authorization" => "Bearer #{key.raw_token}" }
  end

  test "resident pauses and releases own hold with actual state receipt" do
    post pause_api_v1_rhythm_path(@rhythm), params: { reason: "Not this week" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "paused", response.parsed_body.dig("rhythm", "state")
    @rhythm.pause!(holder: @creator, reason: "Human hold too")
    post resume_api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :ok
    assert_equal "paused", response.parsed_body.dig("rhythm", "state")
    assert_equal [ "human" ], @rhythm.open_holds.pluck(:kind)
  end

  test "unselected peer and human API key cannot read or pause" do
    [ ApiKey.generate_for(@creator, name: "Unselected", agent: agents(:code_reviewer)),
      ApiKey.generate_for(@creator, name: "Human") ].each do |key|
      headers = { "Authorization" => "Bearer #{key.raw_token}" }
      get api_v1_rhythm_path(@rhythm), headers: headers
      assert_response :not_found
      post pause_api_v1_rhythm_path(@rhythm), params: { reason: "No" }, headers: headers, as: :json
      assert_response :not_found
    end
  end

  test "removed resident can still release its own hold" do
    @rhythm.pause!(holder: @resident, reason: "Wait")
    @rhythm.update!(agents: [ agents(:code_reviewer) ])
    post resume_api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :ok
    assert_equal "active", response.parsed_body.dig("rhythm", "state")
  end

end
