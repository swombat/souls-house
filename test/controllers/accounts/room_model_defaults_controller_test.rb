require "test_helper"

class Accounts::RoomModelDefaultsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @user = users(:user_1)
    @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @build = @account.rooms.create!(name: "Build")
    sign_in @user
  end

  test "a manager sets and clears a room's model for a resident" do
    patch account_room_model_default_path(@account),
      params: { room_id: @build.to_param, agent_id: @agent.to_param, model_id: "anthropic/claude-fable-5.1" }
    assert_redirected_to account_rooms_path(@account)
    assert_equal "anthropic/claude-fable-5.1", RoomModelDefault.find_by!(room: @build, agent: @agent).model_id
    assert AuditLog.exists?(action: "update_room_model_default")

    patch account_room_model_default_path(@account),
      params: { room_id: "main", agent_id: @agent.to_param, model_id: "anthropic/claude-fable-5.1" }
    assert RoomModelDefault.exists?(room: nil, agent: @agent)

    patch account_room_model_default_path(@account),
      params: { room_id: @build.to_param, agent_id: @agent.to_param, model_id: "default" }
    assert_not RoomModelDefault.exists?(room: @build)
  end

  test "a model off the resident's list is refused with the reason" do
    patch account_room_model_default_path(@account),
      params: { room_id: "main", agent_id: @agent.to_param, model_id: "anthropic/claude-haiku-5.5" }
    assert_redirected_to account_rooms_path(@account)
    assert_equal 0, RoomModelDefault.count
  end

  test "the rooms page lists residents with a model list and the room defaults" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    get account_rooms_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }

    props = inertia_shared_props
    assert_equal [ @agent.to_param ], props.fetch("model_residents").map { |resident| resident["id"] }
    assert_equal [ { "room_id" => @build.to_param, "agent_id" => @agent.to_param, "model_id" => "anthropic/claude-fable-5.1",
      "label" => "Claude Fable 5.1", "problem" => nil } ], props.fetch("room_model_defaults")
  end

  test "a resident whose only alternative was removed stays listed with the stale default to clear" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    @agent.update!(switchable_model_ids: [])
    get account_rooms_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }

    props = inertia_shared_props
    assert_includes props.fetch("model_residents").map { |resident| resident["id"] }, @agent.to_param
    assert_match "list of models", props.fetch("room_model_defaults").sole["problem"]

    patch account_room_model_default_path(@account),
      params: { room_id: @build.to_param, agent_id: @agent.to_param, model_id: "default" }
    assert_equal 0, RoomModelDefault.count
  end

end
