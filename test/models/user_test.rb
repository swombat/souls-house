require "test_helper"

class UserTest < ActiveSupport::TestCase

  # === Core User.register! Method Tests ===

  test "register! creates user, account, and membership for new email" do
    assert_difference [ "User.count", "Account.count", "Membership.count" ] do
      user = User.register!("new@example.com")
      assert user.persisted?
      assert user.personal_account.present?
      assert user.personal_membership.present?
      assert_equal "personal", user.personal_account.account_type
      assert_equal "owner", user.personal_membership.role
    end
  end

  test "register! handles existing unconfirmed user" do
    # Create an unconfirmed user directly
    email = "existing-#{rand(10000)}@example.com"
    existing = User.create!(
      email_address: email
    )
    existing_id = existing.id

    assert_no_difference "User.count" do
      user = User.register!(email)
      assert_equal existing_id, user.id
      assert user.personal_account.present?
    end
  end

  test "register! handles existing confirmed user" do
    existing = users(:user_1)
    initial_account_count = existing.accounts.count

    assert_no_difference [ "User.count", "Account.count", "Membership.count" ] do
      user = User.register!(existing.email_address)
      assert_equal existing.id, user.id
    end
  end

  test "register! validates email format" do
    invalid_emails = [
      "invalid-email",
      "@example.com",
      "user@",
      "",
      nil
    ]

    invalid_emails.each do |email|
      assert_raises(ActiveRecord::RecordInvalid, "Should reject email: #{email.inspect}") do
        User.register!(email)
      end
    end
  end

  test "register! normalizes email address" do
    user = User.register!("  UPPERCASE@EXAMPLE.COM  ")
    assert_equal "uppercase@example.com", user.email_address
  end

  test "register! returns singleton method was_new_record?" do
    new_user = User.register!("brand-new@example.com")
    assert new_user.was_new_record?

    existing_user = User.register!("brand-new@example.com")
    assert_not existing_user.was_new_record?
  end

  # === find_or_create_membership! Method Tests ===

  test "find_or_create_membership! returns existing membership" do
    user = users(:user_1)
    existing_membership = user.personal_membership

    result = user.find_or_create_membership!
    assert_equal existing_membership, result
  end

  test "find_or_create_membership! creates membership for user without account" do
    user = User.create!(email_address: "orphan@example.com")
    # Manually remove the account created by callback for this test
    user.memberships.destroy_all
    user.accounts.destroy_all
    user.reload

    assert_nil user.personal_account
    assert_difference [ "Account.count", "Membership.count" ] do
      membership = user.find_or_create_membership!
      assert membership.persisted?
      assert_equal "owner", membership.role
      assert_equal "personal", membership.account.account_type
    end
  end

  # === ensure_membership_exists Callback Tests ===

  test "ensure_membership_exists creates account and membership on user creation" do
    assert_difference [ "Account.count", "Membership.count" ] do
      user = User.create!(email_address: "callback-test@example.com")

      user.reload
      assert user.personal_account.present?
      assert user.personal_membership.present?
      assert_nil user.default_account
    end
  end

  test "ensure_membership_exists skips if memberships already exist" do
    user = User.create!(email_address: "existing-#{rand(10000)}@example.com")
    initial_count = user.memberships.count

    # Trigger callback again by updating - callback should skip
    user.update!(email_address: "updated-#{rand(10000)}@example.com", password: "newpassword", password_confirmation: "newpassword")

    assert_equal initial_count, user.memberships.count
  end

  # === confirmed? and confirm! Methods ===

  test "confirmed? returns true when user has confirmed account membership" do
    user = users(:user_1)
    assert user.confirmed?
  end

  test "confirmed? returns true when any account membership is confirmed" do
    user = User.create!(email_address: "account-confirmed@example.com")
    # Membership is created automatically and needs confirmation
    user.memberships.first.update!(confirmed_at: Time.current)

    assert user.confirmed?
  end

  test "confirmed? returns false when no memberships are confirmed" do
    user = User.create!(
      email_address: "unconfirmed-test@example.com"
    )
    # Ensure no confirmations exist
    user.memberships.update_all(confirmed_at: nil)

    assert_not user.confirmed?
  end


  # === Authorization Helper Tests ===

  test "authorization helpers work correctly" do
    user = User.register!("auth-user@example.com")
    account = user.personal_account

    # Confirm the user for testing
    user.memberships.first.confirm!

    assert account.accessible_by?(user)
    assert account.manageable_by?(user)
    assert account.owned_by?(user)

    # Test with another account
    other_account = Account.create!(name: "Other", account_type: :team)
    assert_not other_account.accessible_by?(user)
    assert_not other_account.manageable_by?(user)
    assert_not other_account.owned_by?(user)
  end

  test "accessible_by? requires confirmed membership" do
    user = User.create!(email_address: "member-test@example.com")
    account = Account.create!(name: "Test Account", account_type: :team)

    # Add unconfirmed membership
    membership = account.add_user!(user, role: "member")
    assert_not membership.confirmed?

    # Should not be considered a member while unconfirmed
    assert_not account.accessible_by?(user)

    # Confirm and test again
    membership.confirm!
    assert account.accessible_by?(user)
  end

  test "manageable_by? returns true for any confirmed member" do
    team_account = Account.create!(name: "Management Test", account_type: :team)

    # Test owner
    owner = User.create!(email_address: "owner-#{rand(10000)}@example.com")
    team_account.add_user!(owner, role: "owner", skip_confirmation: true)
    assert team_account.manageable_by?(owner)

    # Test admin
    admin = User.create!(email_address: "admin-#{rand(10000)}@example.com")
    team_account.add_user!(admin, role: "admin", skip_confirmation: true)
    assert team_account.manageable_by?(admin)

    # Test member
    member = User.create!(email_address: "member-#{rand(10000)}@example.com")
    team_account.add_user!(member, role: "member", skip_confirmation: true)
    assert team_account.manageable_by?(member)
  end

  test "owned_by? returns true only for owners" do
    team_account = Account.create!(name: "Ownership Test", account_type: :team)

    # Test owner
    owner = User.create!(email_address: "test-owner@example.com")
    team_account.add_user!(owner, role: "owner", skip_confirmation: true)
    assert team_account.owned_by?(owner)

    # Test admin (should not own)
    admin = User.create!(email_address: "test-admin@example.com")
    team_account.add_user!(admin, role: "admin", skip_confirmation: true)
    assert_not team_account.owned_by?(admin)
  end

  # === Critical Update Method Safety Tests (For the bug we fixed) ===

  test "update_column works correctly on User model" do
    user = users(:user_1)
    original_updated_at = user.updated_at

    # Test update_column (should work without callbacks and not update updated_at)
    assert_nothing_raised do
      user.update_column(:email_address, "updated-via-column@example.com")
    end

    user.reload
    assert_equal "updated-via-column@example.com", user.email_address
    assert_equal original_updated_at.to_i, user.updated_at.to_i # Should not change updated_at
  end

  test "update! works correctly on User model" do
    user = users(:user_1)

    # Test update! with required fields
    assert_nothing_raised do
      user.update!(
        email_address: "updated-via-update@example.com",
        password: "newpassword",
        password_confirmation: "newpassword"
      )
      user.profile.update!(
        first_name: "Updated",
        last_name: "User"
      )
    end
    assert_equal "updated-via-update@example.com", user.reload.email_address
  end

  test "save! works correctly on User model" do
    user = User.new(email_address: "save-test@example.com")

    # Test save!
    assert_nothing_raised do
      user.save!
    end
    assert user.persisted?
  end

  # === Validation Tests (Core functionality) ===

  test "validates email_address presence" do
    user = User.new(email_address: "")
    assert_not user.valid?
    assert user.errors[:email_address].include?("can't be blank")
  end

  test "validates email_address uniqueness case insensitive" do
    existing_email = users(:user_1).email_address

    user = User.new(email_address: existing_email.upcase)
    assert_not user.valid?
    assert user.errors[:email_address].include?("has already been taken")
  end

  test "validates password confirmation when password present" do
    user = User.new(
      email_address: "test@example.com",
      password: "password123",
      password_confirmation: "different"
    )

    assert_not user.valid?
    assert user.errors[:password_confirmation].present?
  end

  test "validates password length when password present" do
    user = User.create!(email_address: "test-#{rand(10000)}@example.com")
    user.profile.update!(first_name: "Test", last_name: "User")

    # Too short
    user.password = "12345"
    user.password_confirmation = "12345"
    assert_not user.valid?
    assert user.errors[:password].present?

    # Just right
    user.password = "password123"
    user.password_confirmation = "password123"
    assert user.valid?
  end

  # === Association Tests ===

  test "has_many memberships dependent destroy" do
    user = User.create!(email_address: "destroy-test@example.com")
    membership_id = user.memberships.first.id

    user.destroy

    assert_not Membership.exists?(membership_id)
  end

  test "has_many accounts through memberships" do
    user = users(:user_1)

    assert user.accounts.present?
    assert_includes user.accounts, user.personal_account
    assert user.accounts.all? { |account| account.is_a?(Account) }
  end

  test "personal_account association works correctly" do
    user = users(:user_1)
    personal = user.personal_account

    assert personal.present?
    assert_equal "personal", personal.account_type
    assert_equal user, personal.owner
  end

  test "personal_membership association works correctly" do
    user = users(:user_1)
    personal_membership = user.personal_membership

    assert personal_membership.present?
    assert_equal user, personal_membership.user
    assert_equal user.personal_account, personal_membership.account
    assert_equal "owner", personal_membership.role
  end

  test "default_account returns first confirmed account only" do
    user = users(:user_1)

    # Should return the first confirmed account
    assert_equal user.personal_account, user.default_account

    # Test with unconfirmed user
    unconfirmed = users(:unconfirmed_user)
    unconfirmed.memberships.update_all(confirmed_at: nil)

    assert_nil unconfirmed.default_account
  end

  # === Business Logic Tests ===

  test "can_login? returns true for confirmed users with password" do
    user = users(:user_1)
    assert user.can_login?
  end

  test "can_login? returns false for users without password" do
    user = users(:no_password_user)
    assert_not user.can_login?
  end

  # === Token Generation Tests ===

  test "password reset token is generated on demand" do
    user = users(:user_1)
    assert_nil user.password_reset_token_for_url

    user.send_password_reset
    token = user.reload.password_reset_token_for_url

    assert token.present?
    assert_kind_of String, token
    assert_equal user, User.find_by_token_for(:password_reset, token)
  end

  test "send_password_reset generates token and sets timestamp" do
    user = users(:user_1)
    assert_nil user.password_reset_token_for_url
    assert_nil user.password_reset_sent_at

    user.send_password_reset

    user.reload
    assert user.password_reset_token_for_url.present?
    assert_nil user[:password_reset_token]
    assert user.password_reset_sent_at.present?
    assert user.password_reset_sent_at <= Time.current
  end

  test "password_reset_expired? returns true when token is old" do
    user = users(:user_1)
    user.send_password_reset

    # Token is fresh
    assert_not user.password_reset_expired?

    # Simulate old token
    user.update_column(:password_reset_sent_at, 3.hours.ago)
    assert user.password_reset_expired?
  end

  test "password_reset_expired? returns true when no timestamp" do
    user = users(:user_1)
    assert user.password_reset_expired?
  end

  test "clear_password_reset_token! removes token and timestamp" do
    user = users(:user_1)
    user.send_password_reset

    assert user.password_reset_token_for_url.present?
    assert user.password_reset_sent_at.present?

    user.clear_password_reset_token!
    user.reload

    assert_nil user.password_reset_token_for_url
    assert_nil user.password_reset_sent_at
  end

  # === site_admin and is_site_admin? Tests ===

  test "site_admin returns true when user has is_site_admin set" do
    user = users(:user_1)
    user.update_column(:is_site_admin, true)

    assert user.site_admin
  end

  test "is_site_admin? alias method works correctly" do
    user = users(:user_1)
    user.update_column(:is_site_admin, true)

    assert user.is_site_admin?

    user.update_column(:is_site_admin, false)
    assert_not user.is_site_admin?
  end

  test "site_admin returns false when user does not have is_site_admin set" do
    user = users(:user_1)
    user.update_column(:is_site_admin, false)

    assert_not user.site_admin
  end

  test "site_admin returns true when user belongs to account with is_site_admin" do
    user = users(:user_1)
    user.update_column(:is_site_admin, false)

    # Set the account as site admin
    account = user.personal_account
    account.update_column(:is_site_admin, true)

    assert user.site_admin
  end

  test "site_admin returns true when user belongs to site admin account" do
    user = User.create!(email_address: "member-admin@example.com")
    user.update_column(:is_site_admin, false)

    # Create an account with site admin privileges
    admin_account = Account.create!(name: "Admin Account", account_type: :team, is_site_admin: true)

    # Add user as member
    admin_account.add_user!(user, role: "member", skip_confirmation: true)

    assert user.site_admin
  end

  test "site_admin returns false when user only belongs to non-admin accounts" do
    user = User.create!(email_address: "regular-user@example.com")
    user.update_column(:is_site_admin, false)

    # User's personal account should not be site admin
    user.personal_account.update_column(:is_site_admin, false)

    # Add to a regular team account
    regular_account = Account.create!(name: "Regular Account", account_type: :team, is_site_admin: false)
    regular_account.add_user!(user, role: "member", skip_confirmation: true)

    assert_not user.site_admin
  end

  test "as_json includes site_admin field" do
    user = users(:user_1)
    user.update_column(:is_site_admin, true)

    json = user.as_json
    assert json.key?("site_admin")
    assert_equal true, json["site_admin"]
  end

  # === Theme Preferences Tests ===

  test "theme defaults to system for new users" do
    user = User.new(email_address: "theme-test@example.com")
    assert_equal "system", user.theme
  end

  test "theme can be set to valid values" do
    user = users(:user_1)

    [ "light", "dark", "system" ].each do |theme|
      user.profile.theme = theme
      assert user.valid?, "Theme '#{theme}' should be valid"
      assert_equal theme, user.theme
    end
  end

  test "theme validation rejects invalid values" do
    user = users(:user_1)

    [ "invalid", "blue", "auto", "" ].each do |invalid_theme|
      user.profile.theme = invalid_theme
      assert_not user.profile.valid?, "Theme '#{invalid_theme}' should be invalid"
      assert user.profile.errors[:theme].present?
    end
  end

  test "theme allows nil values" do
    user = users(:user_1)
    user.profile.theme = nil
    assert user.valid?
  end

  test "preferences are stored as JSON" do
    user = users(:user_1)
    user.profile.update!(theme: "dark")

    user.reload
    assert_equal "dark", user.theme
    assert_equal({ "theme" => "dark" }, user.profile.preferences)
  end

  test "as_json includes preferences" do
    user = users(:user_1)
    user.profile.update!(theme: "light")

    json = user.as_json
    assert json.key?("preferences")
    assert_equal({ "theme" => "light" }, json["preferences"])
  end

  # === Full Name and Display Tests ===

  test "full_name returns combined first and last name" do
    user = users(:user_1)
    assert_equal "Test User", user.full_name
  end

  test "full_name handles missing names gracefully" do
    user = User.new(email_address: "noname@example.com")
    assert_nil user.full_name # Returns nil when no profile or name
  end

  test "full_name handles partial names" do
    user = User.create!(email_address: "partial@example.com")
    user.profile.update!(first_name: "John", last_name: nil)
    assert_equal "John", user.full_name # Strip removes trailing space
  end

  # === Complex Site Admin Scenarios ===

  test "site_admin works with multiple account memberships" do
    user = User.create!(email_address: "multi-member@example.com")
    user.update_column(:is_site_admin, false)

    # Add to regular team account
    regular_account = Account.create!(name: "Regular Team", account_type: :team, is_site_admin: false)
    regular_account.add_user!(user, role: "member", skip_confirmation: true)

    assert_not user.site_admin

    # Add to site admin account
    admin_account = Account.create!(name: "Admin Team", account_type: :team, is_site_admin: true)
    admin_account.add_user!(user, role: "member", skip_confirmation: true)

    assert user.site_admin
  end

  test "site_admin prioritizes individual user flag over account flag" do
    user = User.create!(email_address: "priority-test@example.com")
    user.update_column(:is_site_admin, true)

    # Even if personal account is not admin, user should be admin
    user.personal_account.update_column(:is_site_admin, false)

    assert user.site_admin
    assert user.is_site_admin?
  end

  # === Edge Case Tests ===

  test "user without personal account still functions" do
    user = User.create!(email_address: "orphan@example.com")

    # Manually remove personal account for edge case testing
    user.memberships.destroy_all
    user.accounts.destroy_all
    user.reload

    assert_nil user.personal_account
    assert_nil user.personal_membership
    assert_nil user.default_account
    assert_not user.confirmed?
    assert_not user.can_login?
  end

  # === Invitation System Tests ===

  test "created_via_invitation? returns true for unconfirmed users with invitations" do
    # Use find_or_invite to create a user without a personal account
    user = User.find_or_invite("invitedtest@example.com")

    # Remove the auto-created personal account
    user.memberships.destroy_all

    account = accounts(:team)

    Membership.create!(
      account: account,
      user: user,
      role: "member",
      invited_by: users(:admin)
    )

    # Reload to get fresh associations
    user.reload

    assert user.created_via_invitation?
  end

  test "created_via_invitation? returns false for confirmed users" do
    user = users(:owner)
    assert_not user.created_via_invitation?
  end

  test "password validation skipped for users created via invitation" do
    user = User.new(email_address: "invited@example.com")

    # Create invitation without password
    Membership.create!(
      account: accounts(:team),
      user: user,
      role: "member",
      invited_by: users(:admin)
    )

    # User should be valid without password
    assert user.valid?
  end

  test "password validation required for non-invited users" do
    user = User.new(email_address: "regular@example.com", password: "short")

    # Should validate password length for regular users
    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 8 characters)"
  end

  test "find_or_invite creates user without password" do
    assert_difference "User.count" do
      user = User.find_or_invite("brandnew@example.com")
      assert user.persisted?
      assert_nil user.password_digest
    end
  end

  test "find_or_invite finds existing user" do
    existing = users(:owner)

    assert_no_difference "User.count" do
      user = User.find_or_invite(existing.email_address)
      assert_equal existing, user
    end
  end

  test "full_name returns nil when name is blank" do
    user = User.create!(email_address: "nofullname@example.com")
    user.profile.update!(first_name: "", last_name: "")

    assert_nil user.full_name
  end

  # === Avatar Tests ===

  test "avatar attachment works correctly" do
    user = users(:user_1)
    avatar_path = Rails.root.join("test", "fixtures", "files", "test_avatar.png")

    user.avatar.attach(
      io: File.open(avatar_path),
      filename: "test_avatar.png",
      content_type: "image/png"
    )
    assert user.avatar.attached?
    assert_equal "test_avatar.png", user.avatar.filename.to_s
  end

  test "avatar_url returns nil when no avatar attached" do
    user = users(:user_1)
    user.avatar.purge if user.avatar.attached?

    assert_nil user.avatar_url
  end

  test "avatar_url returns URL when avatar attached" do
    user = users(:user_1)
    avatar_path = Rails.root.join("test", "fixtures", "files", "test_avatar.png")
    user.avatar.attach(
      io: File.open(avatar_path),
      filename: "test_avatar.png",
      content_type: "image/png"
    )

    assert_not_nil user.avatar_url
    assert user.avatar_url.include?("test_avatar.png")
  end

  test "initials returns ? when no full name" do
    user = User.new(email_address: "noname@example.com")
    assert_equal "?", user.initials
  end

  test "initials returns first letters of first and last name" do
    user = User.create!(email_address: "test-initials-#{SecureRandom.hex(4)}@example.com")
    user.profile.update!(first_name: "John", last_name: "Doe")
    assert_equal "JD", user.initials
  end

  test "initials handles single name" do
    user = User.create!(email_address: "test-single-#{SecureRandom.hex(4)}@example.com")
    user.profile.update!(first_name: "John", last_name: "")
    assert_equal "J", user.initials
  end

  test "initials handles multiple names" do
    user = User.create!(email_address: "test-multiple-#{SecureRandom.hex(4)}@example.com")
    user.profile.update!(first_name: "Mary Jane", last_name: "Watson Smith")
    # Should take first 2 initials only
    assert_equal "MJ", user.initials
  end

  test "initials are uppercase" do
    user = User.create!(email_address: "test-uppercase-#{SecureRandom.hex(4)}@example.com")
    user.profile.update!(first_name: "john", last_name: "doe")
    assert_equal "JD", user.initials
  end

  test "as_json includes avatar_url and initials" do
    user = users(:user_1)
    avatar_path = Rails.root.join("test", "fixtures", "files", "test_avatar.png")
    user.avatar.attach(
      io: File.open(avatar_path),
      filename: "test_avatar.png",
      content_type: "image/png"
    )

    json = user.as_json
    assert json.key?("avatar_url")
    assert json.key?("initials")
    assert_not_nil json["avatar_url"]
    assert_equal "TU", json["initials"] # Test User
  end

  test "avatar validation accepts valid image types" do
    user = users(:user_1)
    avatar_path = Rails.root.join("test", "fixtures", "files", "test_avatar.png")

    user.avatar.attach(
      io: File.open(avatar_path),
      filename: "test_avatar.png",
      content_type: "image/png"
    )
    assert user.valid?
  end

  test "avatar validation rejects invalid file types" do
    user = users(:user_1)
    text_path = Rails.root.join("test", "fixtures", "files", "test.txt")

    user.avatar.attach(
      io: File.open(text_path),
      filename: "test.txt",
      content_type: "text/plain"
    )
    assert_not user.profile.valid?
    assert_includes user.profile.errors[:avatar].first, "has an invalid content type"
  end

  test "avatar has variants configured" do
    user = users(:user_1)
    avatar_path = Rails.root.join("test", "fixtures", "files", "test_avatar.png")
    user.avatar.attach(
      io: File.open(avatar_path),
      filename: "test_avatar.png",
      content_type: "image/png"
    )

    # Test that variants can be accessed (this confirms they're configured)
    assert_respond_to user.avatar, :variant

    # Test specific variants exist
    thumb_variant = user.avatar.variant(:thumb)
    medium_variant = user.avatar.variant(:medium)

    assert_not_nil thumb_variant.processed
    assert_not_nil medium_variant
  end

end
