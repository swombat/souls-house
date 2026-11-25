require "test_helper"

class AccountPractices::RendererTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @home = @agent.account
    @host = accounts(:team_account)
    @user = users(:user_1)
  end

  test "no block at all when the account keeps no practices" do
    assert_nil AccountPractices::Renderer.section_for_account(@home)
  end

  test "the section names the account, frames the lines and lists them in order, without authors" do
    AccountPractice.add!(account: @home, text: "Second", by: @user)
    AccountPractice.add!(account: @home, text: "Finished threads get the done tag. Don't archive them.", by: @agent, position: 1)

    section = AccountPractices::Renderer.section_for_account(@home)

    assert_equal <<~TEXT.strip, section
      ## Practices of #{@home.name}

      #{AccountPractices::Renderer::FRAMING}

      - Finished threads get the done tag. Don't archive them.
      - Second
    TEXT
    refute_includes section, @agent.name
  end

  test "home-only runs read the home account's practices" do
    AccountPractice.add!(account: @home, text: "Home line", by: @user)

    assert_includes AccountPractices::Renderer.section_for_home(@agent), "Home line"
  end

  test "a conversation in an account the resident neither lives in nor visits gets nothing" do
    AccountPractice.add!(account: @host, text: "Host line", by: @user)
    chat = @host.chats.create!(model_id: "openrouter/auto", title: "Not a guest")

    assert_nil AccountPractices::Renderer.section_for_chat(@agent, chat)
  end

end
