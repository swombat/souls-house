require "test_helper"

class AccountRegistrationFlowTest < ActionDispatch::IntegrationTest

  test "complete user registration flow with account creation" do
    email = "testuser@example.com"

    # Step 1: Sign up
    assert_difference [ "User.count", "Account.count", "Membership.count" ], 1 do
      post signup_path, params: { email_address: email }
    end

    assert_redirected_to check_email_path
    follow_redirect!
    assert_response :success

    # Verify database state after signup
    user = User.last
    account = Account.last
    membership = Membership.last

    assert_equal email, user.email_address
    assert_nil user.password_digest

    assert_equal "#{email}'s Account", account.name
    assert account.personal?
    assert_not_nil account.slug

    assert_equal account.id, membership.account_id
    assert_equal user.id, membership.user_id
    assert_equal "owner", membership.role
    assert_nil membership.confirmed_at
    assert_nil membership.confirmation_token
    assert_not_nil membership.confirmation_token_for_url
    assert_not_nil membership.confirmation_sent_at
    assert_nil membership.invited_by_id

    # Step 2: Confirm email using Membership token
    membership_token = membership.confirmation_token_for_url
    assert_not_nil membership_token

    get email_confirmation_path(token: membership_token)
    assert_redirected_to set_password_path
    follow_redirect!
    assert_response :success

    user.reload
    membership.reload

    # Verify confirmation
    assert membership.confirmed?
    assert user.confirmed?
    assert_not_nil membership.confirmed_at
    assert_nil membership.confirmation_token

    # Step 3: Set password
    patch set_password_path, params: { password: "securePassword123", password_confirmation: "securePassword123", first_name: "Password", last_name: "Set" }
    assert_redirected_to root_path

    user.reload
    assert user.password_digest?
    assert user.can_login?

    # Step 4: Login
    post login_path, params: { email_address: email, password: "securePassword123" }
    assert_redirected_to root_path

    # Verify user is logged in via session
    assert cookies[LocalInstance.current.cookie(:session_id)].present?
    # In tests, we need to decode the signed cookie differently
    user_session = Session.find_by(user: user)
    assert user_session.present?
    assert_equal user.id, user_session.user_id
  end

  test "existing unconfirmed user re-registration preserves account relationships" do
    email = "existing_unconfirmed@example.com"

    # Create initial user
    post signup_path, params: { email_address: email }

    user = User.last
    account = Account.last
    membership = Membership.last
    original_account_id = account.id
    original_user_id = user.id
    original_token = membership.confirmation_token_for_url

    # Re-register same email (should resend confirmation)
    assert_no_difference [ "User.count", "Account.count", "Membership.count" ] do
      post signup_path, params: { email_address: email }
    end

    assert_redirected_to check_email_path

    user.reload
    membership.reload

    # Verify same entities preserved
    assert_equal original_user_id, user.id
    assert_equal original_account_id, account.id

    # Token should be regenerated
    assert_not_equal original_token, membership.confirmation_token_for_url
    assert_not_nil membership.confirmation_sent_at
  end

  test "confirmed user with account cannot re-register" do
    email = "confirmed_user@example.com"

    # Create and confirm user
    post signup_path, params: { email_address: email }
    membership = Membership.last
    get email_confirmation_path(token: membership.confirmation_token_for_url)

    patch set_password_path, params: { password: "password123", password_confirmation: "password123", first_name: "Confirmed", last_name: "User" }

    # Logout first
    delete logout_path

    # Try to re-register
    assert_no_difference [ "User.count", "Account.count", "Membership.count" ] do
      post signup_path, params: { email_address: email }
    end

    assert_redirected_to signup_path
    follow_redirect!
    assert_response :success
  end

  test "account creation with proper owner assignment" do
    email = "owner_test@example.com"

    post signup_path, params: { email_address: email }

    user = User.last
    account = Account.last
    membership = Membership.last

    assert membership.owner?
    assert membership.admin? # owners are also admins
    assert membership.can_manage?
    assert_equal user, account.owner
    assert_equal 1, account.memberships.count
  end

  test "personal account creation enforces single user constraint" do
    # Create personal account with owner
    email = "personal_owner@example.com"
    post signup_path, params: { email_address: email }

    account = Account.last
    assert account.personal?

    # Try to add another user to personal account
    other_user = User.create!(email_address: "other@example.com", password: "password")

    assert_raises(ActiveRecord::RecordInvalid) do
      account.add_user!(other_user, role: "member")
    end
  end

  test "personal account slug generation and uniqueness" do
    email = "slug_test@example.com"

    post signup_path, params: { email_address: email }

    account = Account.last
    assert_not_nil account.slug
    assert account.slug.present?

    # Create another account with similar name
    other_user = User.create!(email_address: "slug_test2@example.com", password: "password")
    other_account = Account.create!(name: account.name, account_type: :personal)

    assert_not_equal account.slug, other_account.slug
  end

  test "account user role validation during registration" do
    email = "role_test@example.com"

    post signup_path, params: { email_address: email }

    membership = Membership.last
    assert_equal "owner", membership.role

    # Personal accounts must have owner role
    membership.role = "member"
    assert_not membership.valid?
    assert membership.errors[:role].present?
  end

  test "invalid email prevents user and account creation" do
    assert_no_difference [ "User.count", "Account.count", "Membership.count" ] do
      post signup_path, params: { email_address: "invalid_email" }
    end

    assert_redirected_to signup_path
    follow_redirect!
    assert_response :success
  end

  test "database state consistency after each registration step" do
    email = "consistency_test@example.com"

    # After signup
    post signup_path, params: { email_address: email }

    user = User.last
    account = Account.last
    membership = Membership.last

    assert_equal user.id, membership.user_id
    assert_equal account.id, membership.account_id
    assert_equal 1, user.accounts.count
    assert_equal 1, account.users.count

    # After confirmation
    token = membership.confirmation_token_for_url
    get email_confirmation_path(token: token)

    user.reload
    membership.reload

    assert membership.confirmed?
    assert user.confirmed?

    # After password set
    patch set_password_path, params: { password: "password123", password_confirmation: "password123", first_name: "Database", last_name: "Consistency" }

    user.reload
    assert user.password_digest?
    assert user.can_login?
  end

  test "user confirmation status via account users" do
    email = "confirmation_status@example.com"

    post signup_path, params: { email_address: email }

    user = User.last
    membership = Membership.last

    # Initially unconfirmed
    assert_not user.confirmed?
    assert_not membership.confirmed?

    # Confirm via Membership
    token = membership.confirmation_token_for_url
    get email_confirmation_path(token: token)

    user.reload
    membership.reload

    # Both should report confirmed
    assert user.confirmed?
    assert membership.confirmed?
  end

  test "authentication flow during registration" do
    email = "auth_flow@example.com"

    # Not authenticated during signup
    post signup_path, params: { email_address: email }
    assert_nil cookies[LocalInstance.current.cookie(:session_id)]

    # Not authenticated during confirmation
    membership = Membership.last
    get email_confirmation_path(token: membership.confirmation_token_for_url)
    assert_nil cookies[LocalInstance.current.cookie(:session_id)]

    # Authenticated after setting password
    patch set_password_path, params: { password: "password123", password_confirmation: "password123", first_name: "Auth", last_name: "Flow" }
    assert cookies[LocalInstance.current.cookie(:session_id)].present?
    # Verify the session belongs to the correct user
    user = User.last
    user_session = Session.find_by(user: user)
    assert user_session.present?
    assert_equal user.id, user_session.user_id
  end

  test "confirmation token management between user and account user" do
    email = "token_management@example.com"

    post signup_path, params: { email_address: email }

    user = User.last
    membership = Membership.last

    # Only Membership should have confirmation token
    assert_nil membership.confirmation_token
    assert_not_nil membership.confirmation_token_for_url
    assert_not_nil membership.confirmation_sent_at

    # Confirm via Membership token
    get email_confirmation_path(token: membership.confirmation_token_for_url)

    user.reload
    membership.reload

    # Token should be cleared after confirmation
    assert_nil membership.confirmation_token
    assert_not_nil membership.confirmed_at
  end

  test "re-registration with existing unconfirmed user updates tokens correctly" do
    email = "reregister@example.com"

    # Step 1: Create unconfirmed user
    post signup_path, params: { email_address: email }

    user = User.last
    membership = Membership.last
    original_membership_token = membership.confirmation_token_for_url

    # Wait a moment to ensure timestamps will be different
    sleep 0.01

    # Step 2: Re-register same email
    assert_no_difference "User.count" do
      assert_no_difference "Account.count" do
        assert_no_difference "Membership.count" do
          post signup_path, params: { email_address: email }
        end
      end
    end

    user.reload
    membership.reload

    # Tokens should be regenerated
    assert_not_equal original_membership_token, membership.confirmation_token_for_url

    # Timestamps should be updated
    assert membership.confirmation_sent_at > 1.second.ago

    # New token should work
    new_token = membership.confirmation_token_for_url
    get email_confirmation_path(token: new_token)
    assert_redirected_to set_password_path
  end

  test "update operations are resilient and work correctly" do
    email = "update_operations@example.com"

    # Create user
    post signup_path, params: { email_address: email }

    user = User.last
    account = Account.last
    membership = Membership.last

    user.reload

    # Confirm email
    get email_confirmation_path(token: membership.confirmation_token_for_url)

    user.reload
    membership.reload

    # Verify confirmation worked
    assert membership.confirmed?
    assert_nil membership.confirmation_token
  end

end
