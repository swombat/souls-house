require "test_helper"

class Agents::Memories::ProtectionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "deprecated")
    @memory = @agent.memories.create!(content: "Test memory", memory_type: :core)

    Setting.instance.update!(allow_agents: true)

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create protects a memory" do
    assert_not @memory.constitutional?

    assert_difference "AuditLog.count" do
      post account_agent_memory_protection_path(@account, @agent, @memory)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/protected/, flash[:notice])
    assert @memory.reload.constitutional?

    audit = AuditLog.last
    assert_equal "memory_protected", audit.action
  end

  test "destroy unprotects a memory" do
    @memory.update!(constitutional: true)

    assert_difference "AuditLog.count" do
      delete account_agent_memory_protection_path(@account, @agent, @memory)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/unprotected/, flash[:notice])
    assert_not @memory.reload.constitutional?

    audit = AuditLog.last
    assert_equal "memory_unprotected", audit.action
  end

  test "requires authentication" do
    delete logout_path

    post account_agent_memory_protection_path(@account, @agent, @memory)
    assert_response :redirect
  end

  test "scopes to current account" do
    other_agent = agents(:other_account_agent)
    other_memory = other_agent.memories.create!(content: "Other memory", memory_type: :core)

    post account_agent_memory_protection_path(@account, other_agent, other_memory)
    assert_response :not_found
  end

end
