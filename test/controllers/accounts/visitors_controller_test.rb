require "test_helper"

class Accounts::VisitorsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @daniel = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
  end

  test "an owner makes a one-time invitation link and sees it listed" do
    sign_in @daniel
    assert @account.owned_by?(@daniel)
    post "/accounts/#{@account.to_param}/visitors/invitations", params: { local_name: "Mira (Seuros)" }, as: :json
    assert_response :created
    url = response.parsed_body["url"]
    assert_match %r{/api/v1/visit/invitations/vinv_}, url
    parsed = Visits::InvitationLink.parse(url)
    assert VisitorInvitation.find_by_token(parsed.token).open?
    assert_equal "Mira (Seuros)", response.parsed_body.dig("listing", "invitations", 0, "local_name")
    refute_includes response.parsed_body["listing"].to_json, parsed.token, "the token is not in the listing"
  end

  test "an owner removes a visitor and its seats close" do
    sign_in @daniel
    admission = VisitorInvitation.issue!(account: @account, user: @daniel)
      .accept!(name: "Mira", home_origin: "https://seuros.example")
    chat = @account.chats.create!(title: "Room", manual_responses: true, model_id: "openrouter/auto",
      agents: [ agents(:research_assistant) ])
    chat.chat_agents.create!(agent: admission.agent)

    delete "/accounts/#{@account.to_param}/visitors/#{admission.to_param}", as: :json
    assert_response :success
    assert_empty response.parsed_body["visitors"]
    refute admission.reload.current?
    refute chat.chat_agents.exists?(agent_id: admission.agent_id)
  end

  test "someone who is not an owner cannot manage visitors" do
    member = @account.memberships.confirmed.where.not(user_id: @daniel.id).first&.user
    skip "fixture has no non-owner member" unless member && !@account.owned_by?(member)
    sign_in member
    post "/accounts/#{@account.to_param}/visitors/invitations", as: :json
    assert_response :forbidden
  end

end
