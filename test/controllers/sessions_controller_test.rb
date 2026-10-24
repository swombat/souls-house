require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
  end

  test "should get login page when not authenticated" do
    get login_path
    assert_response :success
    assert_equal "sessions/new", inertia_component
  end

  test "should redirect to root when accessing login while authenticated" do
    post login_path, params: { email_address: @user.email_address, password: "password123" }

    get login_path
    assert_redirected_to root_path
    assert_equal "You are already signed in.", flash[:notice]
  end

  test "should login with valid credentials" do
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }

    assert_redirected_to root_path
    assert_equal "You have been signed in.", flash[:notice]
  end

  test "should not login with invalid email" do
    post login_path, params: {
      email_address: "wrong@example.com",
      password: "password123"
    }

    assert_redirected_to login_path
    assert_equal "Invalid email or password.", flash[:alert]

    follow_redirect!
    errors = inertia_shared_props["errors"]
    assert errors.present?
    assert_includes errors["email_address"], "Invalid email or password."
  end

  test "should not login with invalid password" do
    post login_path, params: {
      email_address: @user.email_address,
      password: "wrongpassword"
    }

    assert_redirected_to login_path
    assert_equal "Invalid email or password.", flash[:alert]

    follow_redirect!
    errors = inertia_shared_props["errors"]
    assert errors.present?
    assert errors["email_address"].present?
  end

  test "should not login with blank email" do
    post login_path, params: {
      email_address: "",
      password: "password123"
    }

    assert_redirected_to login_path
    assert_equal "Invalid email or password.", flash[:alert]
  end

  test "should not login with blank password" do
    post login_path, params: {
      email_address: @user.email_address,
      password: ""
    }

    assert_redirected_to login_path
    assert_equal "Invalid email or password.", flash[:alert]
  end

  test "should logout successfully" do
    # First login
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path

    # Then logout
    delete logout_path
    assert_redirected_to root_path
    assert_equal "You have been signed out.", flash[:notice]

    # Verify we're logged out by trying to access a protected resource
    # Since we don't have protected resources defined in the controllers we've seen,
    # we'll verify by trying to login again (which should work if we're logged out)
    get login_path
    assert_response :success
  end

  # Rate limiting test is complex to test in isolation
  # as it requires persistent state across requests

  test "successful login creates a session" do
    assert_changes -> { Session.count }, 1 do
      post login_path, params: {
        email_address: @user.email_address,
        password: "password123"
      }
    end
    assert_redirected_to root_path
  end

  test "logout destroys the session" do
    # Login first
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }

    # Then logout and verify session is destroyed
    assert_changes -> { Session.count }, -1 do
      delete logout_path
    end
    assert_redirected_to root_path
  end

end
