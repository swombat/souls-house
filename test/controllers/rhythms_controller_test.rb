require "test_helper"

class RhythmsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @resident = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @attributes = {
      title: "Weekly reflection", opening: "Anything worth bringing forward?",
      cadence: "weekly", weekday: 1, time_of_day: "09:00", timezone: "Madrid",
      append_date: true, resident_ids: [ @resident.to_param ]
    }
  end

  test "create and preview use account residents and server schedule" do
    get preview_account_rhythms_path(@account), params: { rhythm: @attributes }, as: :json
    assert_response :ok
    assert response.parsed_body["next_run_at"]
    assert_includes response.parsed_body["preview_title"], "Weekly reflection"
    assert_equal "Europe/Madrid", response.parsed_body["timezone_identifier"]
    assert_difference "Rhythm.count", 1 do
      post account_rhythms_path(@account), params: { rhythm: @attributes }
    end
    rhythm = Rhythm.order(:id).last
    assert_equal @user, rhythm.creator
    assert_equal [ @resident ], rhythm.agents
    assert_redirected_to account_rhythm_path(@account, rhythm)
  end

  test "index shows each rhythm's last five conversations, marking the ones in the conversation list" do
    rhythm = Rhythm.create!(account: @account, creator_agent: @resident, title: "House watch", opening: "Look round.",
      agents: [ @resident ], cadence: "daily", time_of_day: "09:00", timezone: "UTC", next_run_at: 1.hour.ago)
    chats = 6.times.map { |i| rhythm.fire!(now: Time.current, manual: true, request_key: "k#{i}").occurrence.chat }
    chats.last.messages.create!(role: "user", user: @user, content: "Seen it.", suppress_automatic_dispatch: true)

    get account_rhythms_path(@account)
    assert_response :success
    runs = inertia_shared_props.fetch("rhythms").find { |row| row["id"] == rhythm.to_param }.fetch("recent_runs")
    assert_equal chats.last(5).reverse.map { |chat| account_chat_path(@account, chat) }, runs.pluck("chat_url")
    assert_equal [ true, false, false, false, false ], runs.pluck("listed")
  end

  test "preview does not require private opening or resident selection" do
    get preview_account_rhythms_path(@account), params: { rhythm: @attributes.except(:opening, :resident_ids) }, as: :json
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert response.parsed_body["next_run_at"]
  end

  test "cross-account resident selection fails closed" do
    assert_no_difference "Rhythm.count" do
      post account_rhythms_path(@account), params: { rhythm: @attributes.merge(resident_ids: [ agents(:other_account_agent).to_param ]) }
    end
    assert_response :not_found
  end

  test "invalid schedule is a validation response not an exception" do
    get preview_account_rhythms_path(@account), params: { rhythm: @attributes.merge(time_of_day: "32:99") }, as: :json
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"]["time_of_day"]
  end

  test "an ineligible selected resident remains removable in the edit picker" do
    rhythm = make_rhythm
    @resident.update!(active: false)
    get edit_account_rhythm_path(@account, rhythm), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    resident = response.parsed_body.dig("props", "residents").find { |item| item["id"] == @resident.to_param }
    assert resident["unavailable"]
  end

  test "manual start is idempotent and renders held start honestly" do
    rhythm = make_rhythm
    key = SecureRandom.uuid
    2.times do
      post start_account_rhythm_path(@account, rhythm), params: { request_key: key }
      assert_redirected_to account_rhythm_path(@account, rhythm)
    end
    assert_equal 1, rhythm.occurrences.count
    assert_equal 1, rhythm.occurrences.first.message.message_dispatch.target_agent_ids.size
    rhythm.pause!(holder: @resident, reason: "Not now")
    assert_no_difference "Chat.count" do
      post start_account_rhythm_path(@account, rhythm), params: { request_key: SecureRandom.uuid }
    end
    assert flash[:alert]
    post resume_account_rhythm_path(@account, rhythm)
    assert rhythm.reload.held?
  end

  test "another member sees the list but cannot manage another users rhythm" do
    @account = accounts(:team_account)
    @resident = agents(:other_account_agent)
    rhythm = make_rhythm
    other = users(:existing_user)
    delete logout_path
    post login_path, params: { email_address: other.email_address, password: "password123" }
    assert_no_difference "Rhythm.count" do
      delete account_rhythm_path(@account, rhythm)
    end
    assert_redirected_to account_path(@account)
    assert_not rhythm.manageable_by?(other)
  end

  test "human owner can manage resident authored rhythm and add other residents" do
    rhythm = Rhythm.create!(@attributes.except(:resident_ids).merge(
      account: @account, creator_agent: @resident, agents: [ @resident ]
    ))
    peer = agents(:code_reviewer)
    patch account_rhythm_path(@account, rhythm), params: {
      rhythm: @attributes.merge(resident_ids: [ @resident.to_param, peer.to_param ])
    }
    assert_redirected_to account_rhythm_path(@account, rhythm)
    assert_equal [ @resident.id, peer.id ].sort, rhythm.reload.agent_ids.sort
    assert_nil rhythm.creator
    assert_equal @resident, rhythm.creator_agent
    post pause_account_rhythm_path(@account, rhythm), params: { reason: "Owner hold" }
    assert_equal [ "human" ], rhythm.open_holds.pluck(:kind)
    delete account_rhythm_path(@account, rhythm)
    assert_redirected_to account_rhythms_path(@account)
    assert_not Rhythm.exists?(rhythm.id)
  end

  test "human clearing the selection holds immediately and readding does not silently resume" do
    rhythm = make_rhythm
    patch account_rhythm_path(@account, rhythm), params: { rhythm: { resident_ids: [] } }
    assert_redirected_to account_rhythm_path(@account, rhythm)
    assert_empty rhythm.reload.agents
    assert_equal [ "no_selected_residents" ], rhythm.open_holds.pluck(:reason)
    assert_equal "paused", RhythmPresentation.new(rhythm, user: @user).as_json[:state]

    patch account_rhythm_path(@account, rhythm), params: { rhythm: { resident_ids: [ @resident.to_param ] } }
    assert_redirected_to account_rhythm_path(@account, rhythm)
    assert rhythm.reload.held?
    post resume_account_rhythm_path(@account, rhythm)
    assert_not rhythm.reload.held?
  end

  # Mira #228 finding 1, on the shared save path: a rejected edit must not
  # keep the selection it assigned.
  test "a rejected edit keeps the saved selection and adds no hold" do
    rhythm = make_rhythm
    peer = agents(:code_reviewer)
    patch account_rhythm_path(@account, rhythm), params: { rhythm: { title: "Changed", opening: "", resident_ids: [ peer.to_param ] } }
    assert_response :unprocessable_entity
    rhythm.reload
    assert_equal [ @resident.id ], rhythm.agent_ids
    assert_equal "Weekly reflection", rhythm.title
    patch account_rhythm_path(@account, rhythm), params: { rhythm: { opening: "", resident_ids: [] } }
    assert_response :unprocessable_entity
    assert_equal [ @resident.id ], rhythm.reload.agent_ids
    assert_empty rhythm.open_holds
  end

  test "a malformed resident id is not found rather than an error" do
    rhythm = make_rhythm
    patch account_rhythm_path(@account, rhythm), params: { rhythm: { title: "Changed", resident_ids: [ @resident.to_param, "abc-!" ] } }
    assert_response :not_found
    assert_equal "Weekly reflection", rhythm.reload.title
  end

  private

  def make_rhythm
    Rhythm.create!(@attributes.except(:resident_ids).merge(
      account: @account, creator: @user, agents: [ @resident ]
    ))
  end

end
