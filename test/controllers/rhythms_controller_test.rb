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

  private

  def make_rhythm
    Rhythm.create!(@attributes.except(:resident_ids).merge(
      account: @account, creator: @user, agents: [ @resident ]
    ))
  end

end
