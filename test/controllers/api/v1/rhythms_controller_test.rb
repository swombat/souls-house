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

  test "unselected peer discovers invitation but cannot pause or manage it" do
    headers = headers_for(agents(:code_reviewer))
    get api_v1_rhythm_path(@rhythm), headers: headers
    assert_response :ok
    payload = response.parsed_body["rhythm"]
    assert_equal @rhythm.account.to_param, payload["account_id"]
    assert_equal account_rhythm_path(@rhythm.account, @rhythm), payload["url"]
    assert_empty payload["occurrences"]
    assert payload["can_join"]
    assert_not payload["can_manage"]
    post pause_api_v1_rhythm_path(@rhythm), params: { reason: "No" }, headers: headers, as: :json
    assert_response :forbidden
    patch api_v1_rhythm_path(@rhythm), params: { rhythm: { title: "Hijacked" } }, headers: headers, as: :json
    assert_response :forbidden
    delete api_v1_rhythm_path(@rhythm), headers: headers
    assert_response :forbidden
  end

  test "human key cannot use resident discovery creation or controls" do
    key = ApiKey.generate_for(@creator, name: "Human")
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    get api_v1_rhythms_path, headers: headers
    assert_response :not_found
    get api_v1_rhythm_path(@rhythm), headers: headers
    assert_response :not_found
    post pause_api_v1_rhythm_path(@rhythm), headers: headers
    assert_response :not_found
    post api_v1_rhythms_path, params: { rhythm: attributes }, headers: headers, as: :json
    assert_response :not_found
  end

  test "creation is actually resident attributed and creator can update and delete" do
    assert_difference "Rhythm.count", 1 do
      post api_v1_rhythms_path, params: { rhythm: attributes }, headers: @headers, as: :json
    end
    assert_response :created
    rhythm = Rhythm.order(:id).last
    assert_equal @resident, rhythm.creator_agent
    assert_nil rhythm.creator
    assert_equal [ @resident ], rhythm.agents
    assert_equal "agent", response.parsed_body.dig("rhythm", "creator", "type")
    assert response.parsed_body.dig("rhythm", "can_manage")
    original_next_run = rhythm.next_run_at
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { title: "New", opening: "A different opening", time_of_day: "10:00" } },
      headers: @headers, as: :json
    assert_response :ok
    assert_equal "New", rhythm.reload.title
    assert_equal "A different opening", rhythm.opening
    assert_not_equal original_next_run, rhythm.next_run_at
    delete api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :no_content
    assert_not Rhythm.exists?(rhythm.id)
  end

  test "creation and update reject spoofed creators and selections" do
    %w[creator creator_id creator_agent creator_agent_id user_id resident_ids agent_ids agents].each do |field|
      assert_no_difference "Rhythm.count" do
        post api_v1_rhythms_path, params: { rhythm: attributes.merge(field => [ agents(:code_reviewer).to_param ]) },
          headers: @headers, as: :json
      end
      assert_response :unprocessable_entity
    end
    post api_v1_rhythms_path, params: { rhythm: attributes, creator_id: @creator.to_param },
      headers: @headers, as: :json
    assert_response :unprocessable_entity
    rhythm = resident_rhythm
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { resident_ids: [ agents(:code_reviewer).to_param ] } },
      headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal [ @resident ], rhythm.reload.agents
  end

  test "join and leave affect only self even with spoofed params and are idempotent" do
    peer = agents(:code_reviewer)
    headers = headers_for(peer)
    2.times do
      post join_api_v1_rhythm_path(@rhythm), params: { agent_id: @resident.to_param, resident_ids: [ agents(:other_account_agent).to_param ] },
        headers: headers, as: :json
      assert_response :ok
    end
    assert_equal [ @resident.id, peer.id ].sort, @rhythm.reload.agent_ids.sort
    2.times do
      post leave_api_v1_rhythm_path(@rhythm), params: { agent_id: @resident.to_param },
        headers: headers, as: :json
      assert_response :ok
    end
    assert_equal [ @resident ], @rhythm.reload.agents
    assert_no_difference "ChatAgent.count" do
      get api_v1_rhythm_path(@rhythm), headers: headers
      assert_response :ok
    end
  end

  test "last resident leaves safely and creator explicitly recovers system hold after rejoin" do
    rhythm = resident_rhythm
    post leave_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_empty rhythm.reload.agents
    assert_equal "paused", response.parsed_body.dig("rhythm", "state")
    assert response.parsed_body.dig("rhythm", "can_resume")
    post resume_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :conflict
    assert_equal "no_selected_residents", response.parsed_body["reason"]
    post join_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal "paused", response.parsed_body.dig("rhythm", "state")
    post resume_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal "active", response.parsed_body.dig("rhythm", "state")
    assert rhythm.reload.next_run_at.future?
  end

  test "creator may pause after leaving but cannot erase another residents hold" do
    rhythm = resident_rhythm
    peer = agents(:code_reviewer)
    rhythm.join!(agent: peer)
    rhythm.pause!(holder: peer, reason: "Peer needs quiet")
    post leave_api_v1_rhythm_path(rhythm), headers: @headers
    post pause_api_v1_rhythm_path(rhythm), params: { reason: "Creator quiet" }, headers: @headers, as: :json
    assert_response :ok
    post resume_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal [ peer.id ], rhythm.open_holds.pluck(:agent_id)
    assert_equal "paused", response.parsed_body.dig("rhythm", "state")
    assert_not response.parsed_body.dig("rhythm", "can_resume")
  end

  test "guest discovers and creates only while account membership remains" do
    guest = agents(:other_account_agent)
    headers = headers_for(guest)
    get api_v1_rhythms_path, params: { account_id: @rhythm.account.to_param }, headers: headers
    assert_response :not_found
    membership = GuestMembership.create!(account: @rhythm.account, agent: guest, added_by: @creator)
    get api_v1_rhythms_path, params: { account_id: @rhythm.account.to_param }, headers: headers
    assert_response :ok
    assert_equal [ @rhythm.to_param ], response.parsed_body["rhythms"].map { |item| item["id"] }
    post api_v1_rhythms_path, params: { account_id: @rhythm.account.to_param, rhythm: attributes }, headers: headers, as: :json
    assert_response :created
    rhythm = Rhythm.order(:id).last
    assert_equal guest, rhythm.creator_agent
    assert_equal @rhythm.account, rhythm.account
    rhythm.pause!(holder: guest, reason: "Keep this hold")
    membership.destroy!
    get api_v1_rhythm_path(rhythm), headers: headers
    assert_response :not_found
    post resume_api_v1_rhythm_path(rhythm), headers: headers
    assert_response :not_found
    assert rhythm.held?
  end

  test "a departed guest creator lends only their saved opening not a seat or conversation access" do
    guest = agents(:other_account_agent)
    headers = headers_for(guest)
    GuestMembership.create!(account: @rhythm.account, agent: guest, added_by: @creator)
    post api_v1_rhythms_path, params: { account_id: @rhythm.account.to_param, rhythm: attributes }, headers: headers, as: :json
    assert_response :created
    rhythm = Rhythm.order(:id).last
    rhythm.join!(agent: @resident)
    post leave_api_v1_rhythm_path(rhythm), headers: headers
    assert_response :ok

    occurrence = rhythm.fire!(manual: true, request_key: "saved-invitation").occurrence
    assert_equal guest, occurrence.message.agent
    assert_equal attributes[:opening], occurrence.message.content
    assert_equal [ @resident.id ], occurrence.chat.agent_ids
    assert_equal [ @resident.id ], occurrence.message.message_dispatch.target_agent_ids
    assert_equal guest.name, occurrence.message.rhythm_provenance[:creator_name]
    get api_v1_conversation_path(occurrence.chat), headers: headers
    assert_response :not_found
    get api_v1_rhythm_path(rhythm), headers: headers
    assert_response :ok
    assert response.parsed_body.dig("rhythm", "can_manage")
  end

  test "list is bounded cursor paginated and account scoped with no history" do
    occurrence = @rhythm.fire!(manual: true, request_key: "private-room").occurrence
    100.times do |i|
      Rhythm.create!(attributes.merge(account: @rhythm.account, creator: @creator, agents: [ @resident ], title: "Page #{i}"))
    end
    get api_v1_rhythms_path, headers: @headers
    assert_response :ok
    body = response.parsed_body
    assert_equal 100, body["rhythms"].size
    assert body["next_cursor"]
    assert body["rhythms"].all? { |item| item["account_id"] == @rhythm.account.to_param && item["occurrences"].empty? }
    get api_v1_rhythms_path, params: { cursor: body["next_cursor"], history: true }, headers: @headers
    assert_response :ok
    assert_equal [ @rhythm.to_param ], response.parsed_body["rhythms"].map { |item| item["id"] }
    assert_nil response.parsed_body["next_cursor"]
    assert_empty response.parsed_body["rhythms"].first["occurrences"]
    get api_v1_rhythm_path(@rhythm), params: { history: true }, headers: headers_for(agents(:code_reviewer))
    assert_response :ok
    assert_empty response.parsed_body["rhythm"]["occurrences"]
    get api_v1_conversation_path(occurrence.chat), headers: headers_for(agents(:code_reviewer))
    assert_response :not_found
    get api_v1_rhythms_path, params: { cursor: [] }, headers: @headers
    assert_response :unprocessable_entity
    get api_v1_rhythms_path, params: { account_id: accounts(:team_account).to_param }, headers: @headers
    assert_response :not_found
  end

  test "invalid create and edit return validation errors" do
    post api_v1_rhythms_path, params: { rhythm: attributes.merge(time_of_day: "25:00") }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    rhythm = resident_rhythm
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { opening: "" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal attributes[:opening], rhythm.reload.opening
  end

  test "malformed rhythm shapes return errors not server exceptions" do
    [ nil, "not an object", [ attributes ] ].each do |value|
      post api_v1_rhythms_path, params: { rhythm: value }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      patch api_v1_rhythm_path(@rhythm), params: { rhythm: value }, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "removed resident can still release its own hold" do
    @rhythm.pause!(holder: @resident, reason: "Wait")
    @rhythm.update!(agents: [ agents(:code_reviewer) ])
    post resume_api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :ok
    assert_equal "active", response.parsed_body.dig("rhythm", "state")
  end

  private

  def attributes
    { title: "Self invitation", opening: "Anything taking shape?", cadence: "daily", time_of_day: "09:00", timezone: "UTC" }
  end

  def headers_for(agent)
    @peer_headers ||= {}
    @peer_headers[agent.id] ||= begin
      key = ApiKey.generate_for(@creator, name: "Rhythm peer", agent: agent)
      { "Authorization" => "Bearer #{key.raw_token}" }
    end
  end

  def resident_rhythm
    Rhythm.create!(attributes.merge(account: @rhythm.account, creator_agent: @resident, agents: [ @resident ]))
  end

end
