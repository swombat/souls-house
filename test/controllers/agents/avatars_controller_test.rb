require "test_helper"

class Agents::AvatarsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "a dropped or picked file becomes the resident's picture, and their JSON carries it" do
    patch avatar_account_agent_path(@account, @agent),
      params: { avatar: fixture_file_upload("test_avatar.png", "image/png") }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "appearance")
    @agent.reload
    assert @agent.avatar.attached?
    assert @agent.avatar_url.present?
    assert_equal @agent.avatar_url, @agent.as_json["avatar_url"]
    assert_equal @agent.avatar_url, @agent.as_json(as: :list)["avatar_url"]
    assert_equal @agent.avatar_url, @agent.as_json(as: :resident_card)["avatar_url"]
    assert AuditLog.exists?(action: "set_agent_avatar", auditable: @agent)
  end

  test "a pasted web address is fetched by the house" do
    image = RemoteImageFetch::Result.new(io: StringIO.new(file_fixture("test_avatar.png").binread), filename: "x.png", content_type: "image/png")
    RemoteImageFetch.stub(:call, ->(url) { assert_equal "https://pics.example/x.png", url; image }) do
      patch avatar_account_agent_path(@account, @agent), params: { url: "https://pics.example/x.png" }
    end

    assert_response :success
    assert @agent.reload.avatar.attached?
  end

  test "a refused address comes back under avatar and changes nothing" do
    RemoteImageFetch.stub(:call, ->(_) { raise RemoteImageFetch::Error, "That address isn't on the public internet" }) do
      patch avatar_account_agent_path(@account, @agent), params: { url: "http://10.0.0.1/x.png" }, headers: { "X-Inertia" => true }
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "appearance")
    assert_equal "That address isn't on the public internet", session[:inertia_errors]&.dig(:avatar) || session[:inertia_errors]&.dig("avatar")
    assert_not @agent.reload.avatar.attached?
  end

  test "a string where a file belongs is refused, not read as a blob id" do
    patch avatar_account_agent_path(@account, @agent), params: { avatar: "some-signed-id" }

    assert_response :unprocessable_entity
    assert_not @agent.reload.avatar.attached?
  end

  test "removing keeps the bytes in history and the resident falls back to the icon" do
    @agent.update!(avatar: fixture_file_upload("test_avatar.png", "image/png"))

    delete avatar_account_agent_path(@account, @agent)

    assert_response :success
    @agent.reload
    assert_not @agent.avatar.attached?
    assert_nil @agent.avatar_url
    assert_equal 1, @agent.retired_avatars.count
  end

  test "another account's resident can't be given a picture" do
    other = agents(:other_account_agent)

    patch avatar_account_agent_path(@account, other), params: { avatar: fixture_file_upload("test_avatar.png", "image/png") }

    assert_response :not_found
    assert_not other.reload.avatar.attached?
  end

end
