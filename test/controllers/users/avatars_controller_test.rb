require "test_helper"

class Users::AvatarsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "DELETE destroy removes avatar with Inertia request" do
    avatar_file = fixture_file_upload("test_avatar.png", "image/png")
    @user.avatar.attach(avatar_file)
    assert @user.avatar.attached?

    delete user_avatar_path, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    @user.reload
    assert_not @user.avatar.attached?
    assert flash[:success].present?
    assert_equal "Avatar removed successfully", flash[:success]
  end

  test "DELETE destroy removes avatar without Inertia request" do
    avatar_file = fixture_file_upload("test_avatar.png", "image/png")
    @user.avatar.attach(avatar_file)
    assert @user.avatar.attached?

    delete user_avatar_path

    assert_response :success
    json_response = JSON.parse(@response.body)
    assert json_response["success"]

    @user.reload
    assert_not @user.avatar.attached?
  end

  test "DELETE destroy when no avatar exists still succeeds" do
    assert_not @user.avatar.attached?

    delete user_avatar_path, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    assert flash[:success].present?
  end

  test "requires authentication" do
    delete logout_path

    delete user_avatar_path
    assert_redirected_to login_path
  end

  test "PATCH update takes a dropped or pasted file" do
    patch user_avatar_path, params: { avatar: fixture_file_upload("test_avatar.png", "image/png") }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    assert @user.reload.avatar.attached?
  end

  test "PATCH update fetches a pasted web address" do
    image = RemoteImageFetch::Result.new(io: StringIO.new(file_fixture("test_avatar.png").binread), filename: "me.png", content_type: "image/png")
    RemoteImageFetch.stub(:call, ->(url) { assert_equal "https://pics.example/me.png", url; image }) do
      patch user_avatar_path, params: { url: "https://pics.example/me.png" }
    end

    assert_response :success
    assert_equal @user.reload.avatar_url, JSON.parse(response.body)["avatar_url"]
  end

  test "PATCH update with nothing usable says so and keeps the old picture" do
    @user.avatar.attach(fixture_file_upload("test_avatar.png", "image/png"))

    patch user_avatar_path, params: { url: "" }

    assert_response :unprocessable_entity
    assert_match(/paste its web address/, JSON.parse(response.body)["errors"].first)
    assert @user.reload.avatar.attached?
  end

end
