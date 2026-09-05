require "test_helper"

class Agents::Memories::DiscardsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "deprecated")
    @memory = @agent.memories.create!(content: "Test memory", memory_type: :journal)

    Setting.instance.update!(allow_agents: true)

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create discards a memory and redirects" do
    assert_difference "@agent.memories.kept.count", -1 do
      post account_agent_memory_discard_path(@account, @agent, @memory)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/discarded/, flash[:notice])
    assert @memory.reload.discarded?
  end

  test "create cannot discard a constitutional memory" do
    @memory.update!(constitutional: true)

    assert_no_difference "@agent.memories.kept.count" do
      post account_agent_memory_discard_path(@account, @agent, @memory)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/constitutional/, flash[:alert])
    assert_not @memory.reload.discarded?
  end

  test "destroy restores a discarded memory" do
    @memory.discard!
    assert @memory.discarded?

    delete account_agent_memory_discard_path(@account, @agent, @memory)

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/restored/, flash[:notice])
    assert_not @memory.reload.discarded?
  end

  test "requires authentication" do
    delete logout_path

    post account_agent_memory_discard_path(@account, @agent, @memory)
    assert_response :redirect
  end

  test "scopes to current account" do
    other_agent = agents(:other_account_agent)
    other_memory = other_agent.memories.create!(content: "Other memory", memory_type: :journal)

    post account_agent_memory_discard_path(@account, other_agent, other_memory)
    assert_response :not_found
  end

end
