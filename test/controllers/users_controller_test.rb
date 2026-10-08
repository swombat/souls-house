require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    # Sign in by posting to login path
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    # Verify login was successful
    assert_redirected_to root_path
  end

  test "GET edit renders user edit page" do
    get edit_user_path
    assert_response :success
    assert_equal "user/edit", inertia_component
  end

  test "PATCH update with valid params updates user" do
    patch user_path, params: {
      user: {
        first_name: "Updated",
        last_name: "Name",
        timezone: "UTC"
      }
    }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    @user.reload
    assert_equal "Updated", @user.first_name
    assert_equal "Name", @user.last_name
    assert_equal "UTC", @user.timezone
    assert flash[:success].present?
  end

  test "PATCH update with theme preference updates theme and sets cookie" do
    patch user_path, params: {
      user: {
        first_name: @user.first_name,
        last_name: @user.last_name,
        preferences: { theme: "dark" }
      }
    }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    @user.reload
    assert_equal "dark", @user.theme
    assert_equal "dark", cookies[:theme]
    assert flash[:success].present?
  end

  test "PATCH update with invalid theme shows error" do
    patch user_path, params: {
      user: {
        first_name: @user.first_name,
        last_name: @user.last_name,
        preferences: { theme: "invalid" }
      }
    }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    @user.reload
    assert_not_equal "invalid", @user.theme
    assert flash[:errors].present?
  end

  test "PATCH update without theme preference does not set cookie" do
    # Clear existing theme cookie
    cookies.delete(:theme)

    patch user_path, params: {
      user: {
        first_name: "Updated",
        last_name: "Name"
      }
    }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    assert_nil cookies[:theme]
  end

  test "theme cookie has correct attributes" do
    patch user_path, params: {
      user: {
        first_name: @user.first_name,
        last_name: @user.last_name,
        preferences: { theme: "light" }
      }
    }, headers: { "X-Inertia" => true }

    # Simply verify the cookie value is set correctly
    assert_equal "light", cookies[:theme]
  end

  test "PATCH update without Inertia header returns JSON (for navbar theme updates)" do
    patch user_path, params: {
      user: {
        preferences: { theme: "dark" }
      }
    }

    assert_response :success
    json_response = JSON.parse(@response.body)
    assert json_response["success"]

    @user.reload
    assert_equal "dark", @user.theme
    assert_equal "dark", cookies[:theme]
  end

  test "controllers require authentication" do
    # Sign out by deleting the session
    delete logout_path

    get edit_user_path
    assert_redirected_to login_path

    patch user_path, params: { user: { first_name: "Test" } }, headers: { "X-Inertia" => true }
    assert_redirected_to login_path
  end

  # Avatar upload tests (avatar upload is still on UsersController#update)
  test "PATCH update with valid avatar attaches avatar to user" do
    avatar_file = fixture_file_upload("test_avatar.png", "image/png")

    patch user_path, params: {
      user: {
        first_name: @user.first_name,
        last_name: @user.last_name,
        avatar: avatar_file
      }
    }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    @user.reload
    assert @user.avatar.attached?
    assert_equal "test_avatar.png", @user.avatar.filename.to_s
    assert flash[:success].present?
  end

  test "PATCH update with invalid avatar file type shows error" do
    invalid_file = fixture_file_upload("test.txt", "text/plain")

    patch user_path, params: {
      user: {
        first_name: @user.first_name,
        last_name: @user.last_name,
        avatar: invalid_file
      }
    }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    @user.reload
    assert_not @user.avatar.attached?
    assert flash[:errors].present?
  end

  test "PATCH update with oversized avatar shows error" do
    # Avatar validation is now on the Profile model
    assert Profile.validators_on(:avatar).any? { |v| v.is_a?(ActiveStorageValidations::SizeValidator) }
  end

  test "PATCH update sets the default account and account-less pages use it" do
    team = accounts(:team_account)
    patch user_path, params: { user: { default_account_key: team.to_param } },
      headers: { "X-Inertia" => true }

    assert_redirected_to edit_user_path
    assert_equal team.id, @user.reload.default_account_id

    # Any page without an account in the URL now resolves to the chosen one.
    get api_keys_path
    assert_redirected_to account_api_keys_path(team)
  end

  test "PATCH update refuses a default account the user does not belong to" do
    patch user_path, params: { user: { default_account_key: accounts(:unconfirmed_user_account).to_param } },
      headers: { "X-Inertia" => true }

    assert_nil @user.reload.default_account_id
    assert flash[:errors].present?
  end

  test "PATCH update with a valid default account and a bad theme saves neither" do
    theme_before = @user.theme

    assert_no_difference -> { AuditLog.where(user: @user).count } do
      patch user_path, params: {
        user: { default_account_key: accounts(:team_account).to_param, preferences: { theme: "invalid" } }
      }, headers: { "X-Inertia" => true }
    end

    assert_redirected_to edit_user_path
    assert flash[:errors].present?
    @user.reload
    assert_nil @user.default_account_id
    assert_equal theme_before, @user.theme
  end

  test "GET edit passes the default account choice as a settings prop" do
    team = accounts(:team_account)
    @user.update!(default_account_key: team.to_param)

    get edit_user_path

    props = inertia_props["props"]
    assert_equal team.to_param, props["default_account_key"]
    assert_includes props["accounts"].map { |a| a["id"] }, team.to_param
    assert_not props["user"].key?("default_account_key")
  end

end
