require "test_helper"

class Agents::MemoriesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "deprecated")

    Setting.instance.update!(allow_agents: true)

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create creates a core memory and redirects" do
    assert_difference "@agent.memories.count", 1 do
      post account_agent_memories_path(@account, @agent), params: {
        memory: { content: "Test core memory", memory_type: "core" }
      }
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/created/, flash[:notice])

    memory = @agent.memories.last
    assert_equal "Test core memory", memory.content
    assert_equal "core", memory.memory_type
  end

  test "create creates a journal memory" do
    assert_difference "@agent.memories.count", 1 do
      post account_agent_memories_path(@account, @agent), params: {
        memory: { content: "Test journal entry", memory_type: "journal" }
      }
    end

    memory = @agent.memories.last
    assert_equal "journal", memory.memory_type
  end

  test "create is blocked for external agents" do
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7)

    assert_no_difference "@agent.memories.count" do
      post account_agent_memories_path(@account, @agent), params: {
        memory: { content: "Runtime-owned memory", memory_type: "core" }
      }
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "memory")
    assert_match(/self-managed/, flash[:alert])
  end

  test "create fails with blank content" do
    assert_no_difference "@agent.memories.count" do
      post account_agent_memories_path(@account, @agent), params: {
        memory: { content: "", memory_type: "core" }
      }
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
  end

  test "requires authentication" do
    delete logout_path

    post account_agent_memories_path(@account, @agent), params: {
      memory: { content: "Test", memory_type: "core" }
    }
    assert_response :redirect
  end

  test "scopes to current account" do
    other_agent = agents(:other_account_agent)

    post account_agent_memories_path(@account, other_agent), params: {
      memory: { content: "Test", memory_type: "core" }
    }
    assert_response :not_found
  end

end
