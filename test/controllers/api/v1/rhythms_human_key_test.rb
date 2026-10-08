require "test_helper"

# Human (account) keys drive rhythms with the web's authority: any confirmed
# member may list, read, preview and create; only the creator or the account
# owner may update, delete, pause, resume or start.
class Api::V1::RhythmsHumanKeyTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_agents: true)
    @owner = users(:user_1)
    @account = accounts(:personal_account)
    @resident = agents(:research_assistant)
    @peer = agents(:code_reviewer)
    @headers = human_headers(@owner, @account)
    @attributes = {
      title: "Weekly reflection", opening: "Anything worth bringing forward?",
      cadence: "weekly", weekday: 1, time_of_day: "09:00", timezone: "Madrid",
      append_date: true, resident_ids: [ @resident.to_param ]
    }
  end

  test "a member creates a human-authored rhythm choosing residents, then reads it" do
    assert_difference "Rhythm.count", 1 do
      post api_v1_rhythms_path, params: { rhythm: @attributes }, headers: @headers, as: :json
    end
    assert_response :created
    rhythm = Rhythm.order(:id).last
    assert_equal @owner, rhythm.creator
    assert_nil rhythm.creator_agent
    assert_equal [ @resident ], rhythm.agents
    assert rhythm.next_run_at.future?
    body = response.parsed_body["rhythm"]
    assert_equal "user", body.dig("creator", "type")
    assert body["can_manage"]
    assert_not body["can_join"]
    assert_equal "no-store", response.headers["Cache-Control"]

    get api_v1_rhythms_path, headers: @headers
    assert_response :ok
    assert_includes response.parsed_body["rhythms"].map { |item| item["id"] }, rhythm.to_param
    get api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal [ @resident.to_param ], response.parsed_body.dig("rhythm", "resident_ids")
  end

  test "show includes the web history and list includes recent runs" do
    rhythm = make_rhythm
    occurrence = rhythm.fire!(manual: true, request_key: "history").occurrence
    get api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal [ occurrence.id.to_s ], response.parsed_body.dig("rhythm", "occurrences").pluck("id")
    get api_v1_rhythms_path, headers: @headers
    row = response.parsed_body["rhythms"].find { |item| item["id"] == rhythm.to_param }
    assert_equal [ account_chat_path(@account, occurrence.chat) ], row["recent_runs"].pluck("chat_url")
  end

  test "preview needs neither opening nor residents and reports invalid schedules" do
    get preview_api_v1_rhythms_path, params: { rhythm: @attributes.except(:opening, :resident_ids) }, headers: @headers
    assert_response :ok
    assert response.parsed_body["next_run_at"]
    assert_includes response.parsed_body["preview_title"], "Weekly reflection"
    assert_equal "Europe/Madrid", response.parsed_body["timezone_identifier"]
    assert_equal "no-store", response.headers["Cache-Control"]
    get preview_api_v1_rhythms_path, params: { rhythm: @attributes.merge(time_of_day: "32:99") }, headers: @headers
    assert_response :unprocessable_entity
    assert response.parsed_body.dig("errors", "time_of_day")
  end

  test "validation failures and forged authorship return 422 without saving" do
    assert_no_difference "Rhythm.count" do
      post api_v1_rhythms_path, params: { rhythm: @attributes.merge(time_of_day: "25:00") }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      assert response.parsed_body.dig("errors", "time_of_day")
      post api_v1_rhythms_path, params: { rhythm: @attributes.merge(resident_ids: []) }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      assert response.parsed_body.dig("errors", "agents")
      %w[creator_id creator_agent_id user_id agent_ids].each do |field|
        post api_v1_rhythms_path, params: { rhythm: @attributes.merge(field => @peer.to_param) }, headers: @headers, as: :json
        assert_response :unprocessable_entity
      end
      post api_v1_rhythms_path, params: { rhythm: "nope" }, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
    rhythm = make_rhythm
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { opening: "" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal @attributes[:opening], rhythm.reload.opening
  end

  test "selecting a resident from another account fails closed" do
    assert_no_difference "Rhythm.count" do
      post api_v1_rhythms_path, params: { rhythm: @attributes.merge(resident_ids: [ agents(:other_account_agent).to_param ]) },
        headers: @headers, as: :json
    end
    assert_response :not_found
  end

  # Mira #228 finding 1: assigning resident_ids to a saved rhythm writes the
  # join rows at once, so a rejected edit must roll the selection back too.
  test "a rejected update keeps the saved selection, scalars and holds" do
    rhythm = make_rhythm
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { title: "Changed", opening: "", resident_ids: [ @peer.to_param ] } },
      headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert response.parsed_body.dig("errors", "opening")
    rhythm.reload
    assert_equal [ @resident.id ], rhythm.agent_ids
    assert_equal "Weekly reflection", rhythm.title
    assert_equal @attributes[:opening], rhythm.opening
    assert_empty rhythm.open_holds

    patch api_v1_rhythm_path(rhythm), params: { rhythm: { opening: "", resident_ids: [] } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    rhythm.reload
    assert_equal [ @resident.id ], rhythm.agent_ids
    assert_empty rhythm.open_holds
  end

  # Mira #228 finding 2: every resident id must decode to one resident, or
  # nothing is saved.
  test "undecodable or malformed resident ids fail closed without saving" do
    undecodable = "zzzzzz"
    assert_empty Agent.hashids.decode(undecodable)
    malformed = [ [ @resident.to_param, undecodable ], [ @resident.to_param, "abc-!" ], [ "#{@peer.id}junk" ],
      [ Agent.hashids.encode(@resident.id, @peer.id) ] ]
    malformed.each do |ids|
      assert_no_difference "Rhythm.count" do
        post api_v1_rhythms_path, params: { rhythm: @attributes.merge(resident_ids: ids) }, headers: @headers, as: :json
      end
      assert_response :not_found, "create with #{ids.inspect}"
    end

    rhythm = make_rhythm
    malformed.each do |ids|
      patch api_v1_rhythm_path(rhythm), params: { rhythm: { title: "Changed", resident_ids: ids } }, headers: @headers, as: :json
      assert_response :not_found, "update with #{ids.inspect}"
      rhythm.reload
      assert_equal [ @resident.id ], rhythm.agent_ids
      assert_equal "Weekly reflection", rhythm.title
    end
  end

  test "owner manages a resident-authored rhythm and adds residents without taking authorship" do
    rhythm = Rhythm.create!(@attributes.except(:resident_ids).merge(account: @account, creator_agent: @resident, agents: [ @resident ]))
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { title: "Renamed", resident_ids: [ @resident.to_param, @peer.to_param ] } },
      headers: @headers, as: :json
    assert_response :ok
    rhythm.reload
    assert_equal "Renamed", rhythm.title
    assert_equal [ @resident.id, @peer.id ].sort, rhythm.agent_ids.sort
    assert_equal @resident, rhythm.creator_agent
    assert_nil rhythm.creator
    delete api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :no_content
    assert_not Rhythm.exists?(rhythm.id)
  end

  test "a human resume releases human holds but never a resident's own hold" do
    rhythm = make_rhythm
    rhythm.pause!(holder: @resident, reason: "Resident needs quiet")
    post pause_api_v1_rhythm_path(rhythm), params: { reason: "Owner hold" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "held", response.parsed_body["result"]
    assert_equal %w[agent human], rhythm.open_holds.pluck(:kind).sort
    assert_equal "Owner hold", rhythm.open_holds.find_by(kind: "human").reason

    post resume_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal "held", response.parsed_body["result"]
    assert_equal "paused", response.parsed_body.dig("rhythm", "state")
    assert_equal [ [ "agent", @resident.id ] ], rhythm.open_holds.pluck(:kind, :agent_id)
    hold = response.parsed_body.dig("rhythm", "holds").sole
    assert_not hold["can_release"]
    assert_not response.parsed_body.dig("rhythm", "can_resume")
  end

  test "clearing the selection holds at once and readding needs an explicit resume" do
    rhythm = make_rhythm
    patch api_v1_rhythm_path(rhythm), params: { rhythm: { resident_ids: [] } }, headers: @headers, as: :json
    assert_response :ok
    assert_empty rhythm.reload.agents
    assert_equal [ "no_selected_residents" ], rhythm.open_holds.pluck(:reason)
    post resume_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :conflict
    assert_equal "no_selected_residents", response.parsed_body["reason"]

    patch api_v1_rhythm_path(rhythm), params: { rhythm: { resident_ids: [ @resident.to_param ] } }, headers: @headers, as: :json
    assert_response :ok
    assert rhythm.reload.held?
    post resume_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :ok
    assert_equal "active", response.parsed_body["result"]
    assert_not rhythm.reload.held?
  end

  test "manual start is idempotent per request key and refuses honestly" do
    rhythm = make_rhythm
    key = SecureRandom.uuid
    post start_api_v1_rhythm_path(rhythm), params: { request_key: key }, headers: @headers, as: :json
    assert_response :created
    occurrence = response.parsed_body["occurrence"]
    assert_equal "created", response.parsed_body["result"]
    assert occurrence["manual"]
    assert_equal rhythm.occurrences.sole.chat.to_param, occurrence["conversation_id"]
    post start_api_v1_rhythm_path(rhythm), params: { request_key: key }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "duplicate", response.parsed_body["result"]
    assert_equal occurrence["id"], response.parsed_body.dig("occurrence", "id")
    assert_equal 1, rhythm.occurrences.count

    post start_api_v1_rhythm_path(rhythm), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_request", response.parsed_body["result"]

    rhythm.pause!(holder: @resident, reason: "Not now")
    assert_no_difference "Chat.count" do
      post start_api_v1_rhythm_path(rhythm), params: { request_key: SecureRandom.uuid }, headers: @headers, as: :json
    end
    assert_response :conflict
    assert_equal "held", response.parsed_body["result"]
  end

  test "a member who is not creator or owner reads but cannot manage" do
    team = accounts(:team_account)
    rhythm = Rhythm.create!(@attributes.merge(resident_ids: [ agents(:other_account_agent).id ],
      account: team, creator: @owner))
    member = users(:existing_user)
    headers = human_headers(member, team)
    get api_v1_rhythms_path, headers: headers
    assert_response :ok
    assert_equal [ rhythm.to_param ], response.parsed_body["rhythms"].map { |item| item["id"] }
    assert_not response.parsed_body["rhythms"].first["can_manage"]
    get api_v1_rhythm_path(rhythm), headers: headers
    assert_response :ok

    patch api_v1_rhythm_path(rhythm), params: { rhythm: { title: "Mine now" } }, headers: headers, as: :json
    assert_response :forbidden
    assert_equal "Only the creator or account owner can manage this rhythm.", response.parsed_body["error"]
    post pause_api_v1_rhythm_path(rhythm), headers: headers
    assert_response :forbidden
    rhythm.pause!(holder: @owner, reason: "Owner hold")
    post resume_api_v1_rhythm_path(rhythm), headers: headers
    assert_response :forbidden
    post start_api_v1_rhythm_path(rhythm), params: { request_key: "x" }, headers: headers, as: :json
    assert_response :forbidden
    assert_no_difference "Rhythm.count" do
      delete api_v1_rhythm_path(rhythm), headers: headers
    end
    assert_response :forbidden
    assert_equal "Weekly reflection", rhythm.reload.title
    assert rhythm.held?

    assert_difference "Rhythm.count", 1 do
      post api_v1_rhythms_path, params: { rhythm: @attributes.merge(resident_ids: [ agents(:other_account_agent).to_param ]) },
        headers: headers, as: :json
    end
    assert_response :created
    assert_equal member, Rhythm.order(:id).last.creator
  end

  test "another account's rhythms are not found" do
    other = Rhythm.create!(@attributes.merge(resident_ids: [ agents(:other_account_agent).id ],
      account: accounts(:team_account), creator: @owner))
    get api_v1_rhythm_path(other), headers: @headers
    assert_response :not_found
    post pause_api_v1_rhythm_path(other), headers: @headers
    assert_response :not_found
    delete api_v1_rhythm_path(other), headers: @headers
    assert_response :not_found
    assert Rhythm.exists?(other.id)
    get api_v1_rhythms_path, params: { account_id: accounts(:team_account).to_param }, headers: @headers
    assert_response :not_found
  end

  test "a person who left the account loses the door" do
    rhythm = make_rhythm
    team = accounts(:team_account)
    member = users(:existing_user)
    headers = human_headers(member, team)
    Membership.where(account: team, user: member).destroy_all
    get api_v1_rhythms_path, headers: headers
    assert_response :not_found
    team_rhythm = Rhythm.create!(@attributes.merge(resident_ids: [ agents(:other_account_agent).id ], account: team, creator: @owner))
    get api_v1_rhythm_path(team_rhythm), headers: headers
    assert_response :not_found
    assert rhythm.persisted?
  end

  test "human keys follow the web's agents switch" do
    Setting.instance.update!(allow_agents: false)
    get api_v1_rhythms_path, headers: @headers
    assert_response :forbidden
    post api_v1_rhythms_path, params: { rhythm: @attributes }, headers: @headers, as: :json
    assert_response :forbidden
  end

  test "join and leave stay resident-only, and manual start stays human-only" do
    rhythm = make_rhythm
    post join_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :forbidden
    post leave_api_v1_rhythm_path(rhythm), headers: @headers
    assert_response :forbidden
    assert_equal [ @resident ], rhythm.reload.agents

    resident_key = ApiKey.generate_for(@owner, name: "Resident", agent: @resident)
    resident_headers = { "Authorization" => "Bearer #{resident_key.raw_token}" }
    assert_no_difference "RhythmOccurrence.count" do
      post start_api_v1_rhythm_path(rhythm), params: { request_key: "r" }, headers: resident_headers, as: :json
    end
    assert_response :forbidden
    get preview_api_v1_rhythms_path, params: { rhythm: @attributes.except(:opening, :resident_ids) }, headers: resident_headers
    assert_response :ok
    assert response.parsed_body["next_run_at"]
    post api_v1_rhythms_path, params: { rhythm: @attributes }, headers: resident_headers, as: :json
    assert_response :unprocessable_entity
  end

  private

  def human_headers(user, account)
    key = ApiKey.generate_for(user, name: "Rhythms by hand", account: account)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

  def make_rhythm
    Rhythm.create!(@attributes.except(:resident_ids).merge(account: @account, creator: @owner, agents: [ @resident ]))
  end

end
