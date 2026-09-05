require "test_helper"

class AccountTest < ActiveSupport::TestCase

  test "new accounts do not use shared AI credentials by default" do
    account = Account.create!(name: "Bring Your Own Keys", account_type: :team)

    assert_not account.use_system_ai_credentials?
  end

  test "account AI key takes precedence over shared credentials" do
    account = accounts(:team_account)
    account.update!(anthropic_api_key: "account-key", use_system_ai_credentials: true)

    Rails.application.credentials.stub(:dig, "shared-key") do
      assert_equal "account-key", account.ai_api_key(:anthropic)
    end
  end

  test "shared AI credentials are only used when fallback is enabled" do
    account = accounts(:team_account)
    account.update!(anthropic_api_key: nil, use_system_ai_credentials: true)

    Rails.application.credentials.stub(:dig, "shared-key") do
      assert_equal "shared-key", account.ai_api_key(:anthropic)

      account.update!(use_system_ai_credentials: false)
      assert_nil account.ai_api_key(:anthropic)
    end
  end

  test "provider key export includes Moonshot and omits placeholders" do
    account = accounts(:team_account)
    account.update!(
      use_system_ai_credentials: false,
      moonshot_api_key: "moonshot-key",
      openrouter_api_key: "<OPENROUTER_API_KEY>"
    )

    assert_equal({ "MOONSHOT_API_KEY" => "moonshot-key" }, account.ai_provider_keys)
  end

  # === Core add_user! Method Tests ===

  test "add_user! creates new Membership for new membership" do
    account = accounts(:team_account)
    new_user = User.create!(email_address: "newmember@example.com")

    assert_difference "Membership.count" do
      membership = account.add_user!(new_user, role: "member")
      assert membership.persisted?
      assert_equal "member", membership.role
      assert_equal account, membership.account
      assert_equal new_user, membership.user
      assert_not membership.confirmed? # Should require confirmation by default
    end
  end

  test "add_user! with skip_confirmation creates confirmed membership" do
    account = accounts(:team_account)
    new_user = User.create!(email_address: "skipmember@example.com")

    membership = account.add_user!(new_user, role: "admin", skip_confirmation: true)

    # When skip_confirmation is true, the Membership should be confirmed
    # The Confirmable module sets confirmed_at when needs_confirmation? returns false
    membership.reload
    assert membership.confirmed?, "Membership should be confirmed when skip_confirmation is true"
    assert_nil membership.confirmation_token
  end

  test "add_user! enforces personal account user limit" do
    personal_account = accounts(:personal_account)
    new_user = User.create!(email_address: "seconduser@example.com")

    # Should fail because personal accounts can only have one user
    assert_raises(ActiveRecord::RecordInvalid) do
      personal_account.add_user!(new_user, role: "owner", skip_confirmation: true)
    end
  end

  # === Personal vs Team Account Tests ===

  test "personal accounts validate single user limit" do
    account = Account.create!(name: "Personal Test", account_type: :personal)
    user1 = User.create!(email_address: "user1@example.com")
    user2 = User.create!(email_address: "user2@example.com")

    # First user should work
    membership1 = account.add_user!(user1, role: "owner", skip_confirmation: true)
    assert membership1.persisted?

    # Second user should fail validation
    assert_raises(ActiveRecord::RecordInvalid) do
      account.add_user!(user2, role: "owner", skip_confirmation: true)
    end
  end

  test "team accounts allow multiple users" do
    account = Account.create!(name: "Team Test", account_type: :team)
    user1 = User.create!(email_address: "teamuser1@example.com")
    user2 = User.create!(email_address: "teamuser2@example.com")

    assert_nothing_raised do
      account.add_user!(user1, role: "owner", skip_confirmation: true)
      account.add_user!(user2, role: "member", skip_confirmation: true)
    end

    assert_equal 2, account.users.count
  end

  # === Slug Generation Tests ===

  test "generates slug from name on creation" do
    account = Account.create!(name: "My Test Account", account_type: :personal)
    assert_equal "my-test-account", account.slug
  end

  test "ensures unique slugs by appending random string" do
    Account.create!(name: "Same Name", account_type: :personal)
    account2 = Account.create!(name: "Same Name", account_type: :personal)

    assert_not_equal account2.slug, "same-name"
    assert account2.slug.start_with?("same-name-")
    assert_match(/same-name-[a-f0-9]{8}/, account2.slug)
  end

  test "slug generation handles special characters" do
    account = Account.create!(name: "Test & Account!", account_type: :personal)
    assert_equal "test-account", account.slug
  end

  # === Association Tests ===

  test "has_many memberships dependent destroy" do
    account = Account.create!(name: "Destroy Test", account_type: :team)
    user = User.create!(email_address: "accountdestroytest@example.com")
    membership = account.add_user!(user, role: "owner", skip_confirmation: true)
    membership_id = membership.id

    account.destroy

    assert_not Membership.exists?(membership_id)
  end

  test "has_many users through memberships" do
    account = accounts(:team_account)

    assert account.users.present?
    assert_includes account.users, users(:user_1)
  end

  test "owner association returns owner user" do
    account = accounts(:personal_account)
    owner = users(:user_1)

    assert_equal owner, account.owner
  end

  test "owner_membership association works correctly" do
    account = accounts(:personal_account)
    owner_membership = account.owner_membership

    assert owner_membership.present?
    assert_equal "owner", owner_membership.role
    assert_equal users(:user_1), owner_membership.user
  end

  test "owner association returns nil when no owner exists" do
    account = Account.create!(name: "No Owner Account", account_type: :team)
    user = User.create!(email_address: "member-only@example.com")
    account.add_user!(user, role: "member", skip_confirmation: true)

    assert_nil account.owner
  end

  test "has_many users through memberships includes all confirmed users" do
    account = accounts(:team_account)

    confirmed_users = account.users

    # Should include all confirmed users
    confirmed_users.each do |user|
      membership = account.memberships.find_by(user: user)
      assert membership.confirmed?, "User #{user.email_address} should be confirmed"
    end
  end

  # === GitHub Integration Association Tests ===

  test "has_one github_integration association" do
    account = accounts(:team_account)
    integration = GithubIntegration.create!(account: account)

    assert_equal integration, account.github_integration
  end

  test "github_commits_context delegates to integration" do
    account = accounts(:another_team)
    integration = GithubIntegration.create!(
      account: account,
      enabled: true,
      repository_full_name: "owner/repo",
      recent_commits: [
        { "sha" => "abc12345", "date" => "2026-02-05", "message" => "Fix bug", "author" => "Dev" }
      ]
    )

    context = account.github_commits_context
    assert_includes context, "# Recent Commits to owner/repo"
    assert_includes context, "Fix bug (Dev)"
  end

  test "github_commits_context returns nil without integration" do
    account = Account.create!(name: "No GitHub", account_type: :team)
    assert_nil account.github_commits_context
  end

  test "github_commits_context returns nil when integration has no commits" do
    account = Account.create!(name: "Empty GitHub", account_type: :team)
    GithubIntegration.create!(account: account, enabled: true, recent_commits: [])

    assert_nil account.github_commits_context
  end

  # === Validation Tests ===

  test "validates name presence when not using callback" do
    account = Account.new(name: "Test Account", account_type: :personal)
    assert account.valid?

    account.name = ""
    assert_not account.valid?
    assert account.errors[:name].include?("can't be blank")
  end

  test "validates account_type presence" do
    account = Account.new(name: "Test Account")
    account.account_type = nil
    assert_not account.valid?
    assert account.errors[:account_type].include?("can't be blank")
  end

  # === Enum Tests ===

  test "account_type enum works correctly" do
    personal = Account.create!(name: "Personal", account_type: :personal)
    team = Account.create!(name: "Team", account_type: :team)

    assert personal.personal?
    assert_not personal.team?

    assert team.team?
    assert_not team.personal?
  end

  test "account_type enum scopes work" do
    personal_count = Account.personal.count
    team_count = Account.team.count

    # Create one of each type
    Account.create!(name: "New Personal", account_type: :personal)
    Account.create!(name: "New Team", account_type: :team)

    assert_equal personal_count + 1, Account.personal.count
    assert_equal team_count + 1, Account.team.count
  end

  # === Business Logic Tests ===

  test "personal_account_for? returns true for personal account owner" do
    personal_account = accounts(:personal_account)
    owner = users(:user_1)
    other_user = users(:confirmed_user)

    assert personal_account.personal_account_for?(owner)
    assert_not personal_account.personal_account_for?(other_user)
  end

  test "personal_account_for? returns false for team accounts" do
    team_account = accounts(:team_account)
    user = users(:user_1)

    assert_not team_account.personal_account_for?(user)
  end

  # === Account Type Conversion Tests ===

  test "make_personal! converts team account to personal when single user" do
    account = Account.create!(name: "Solo Team", account_type: :team)
    user = User.create!(email_address: "solo@example.com")
    account.add_user!(user, role: "owner", skip_confirmation: true)

    assert account.team?
    assert account.can_be_personal?

    account.make_personal!

    assert account.personal?
    assert_equal "owner", account.memberships.first.role
  end

  test "make_personal! does nothing for team account with multiple users" do
    account = accounts(:team_account)
    original_type = account.account_type

    account.make_personal!

    assert_equal original_type, account.reload.account_type
  end

  test "make_personal! does nothing for already personal account" do
    account = accounts(:personal_account)
    original_type = account.account_type

    account.make_personal!

    assert_equal original_type, account.reload.account_type
  end

  test "make_team! converts personal account to team with new name" do
    account = accounts(:personal_account)

    assert account.personal?

    account.make_team!("New Team Name")

    assert account.team?
    assert_equal "New Team Name", account.name
  end

  test "make_team! does nothing for already team account" do
    account = accounts(:team_account)
    original_name = account.name

    account.make_team!("Should Not Change")

    assert_equal original_name, account.reload.name
    assert account.team?
  end

  test "can_be_personal? returns true for team with single user" do
    account = Account.create!(name: "Single User Team", account_type: :team)
    user = User.create!(email_address: "singleuser@example.com")
    account.add_user!(user, role: "owner", skip_confirmation: true)

    assert account.can_be_personal?
  end

  test "can_be_personal? returns false for team with multiple users" do
    account = accounts(:team_account)

    assert_not account.can_be_personal?
  end

  test "can_be_personal? returns false for personal account" do
    account = accounts(:personal_account)

    assert_not account.can_be_personal?
  end

  test "can_be_personal? returns false when team has pending invitations" do
    account = accounts(:another_team)  # Has 3 users: one confirmed, one admin, one pending

    # Verify test data assumption
    assert_equal 3, account.memberships.count
    assert account.memberships.where(confirmed_at: nil).exists?, "Should have pending invitations"

    assert_not account.can_be_personal?
  end

  test "make_personal! fails when team has pending invitations" do
    account = accounts(:another_team)  # Has 3 users: one confirmed, one admin, one pending
    original_type = account.account_type

    # Should not convert because total memberships.count > 1
    account.make_personal!

    # Should remain as team account
    assert_equal original_type, account.reload.account_type
    assert account.team?
  end

  test "make_personal! works when all extra users are removed" do
    account = accounts(:another_team)

    # Remove the pending invitation and one confirmed user, leaving only one confirmed user
    pending_invitation = account.memberships.find_by(confirmed_at: nil)
    pending_invitation.destroy!

    # Remove the admin (user_1), keep only the member (user_3)
    admin_membership = account.memberships.find_by(user_id: 1)
    admin_membership.destroy!

    assert_equal 1, account.memberships.count
    assert account.can_be_personal?

    account.make_personal!

    assert account.personal?
    assert_equal "owner", account.memberships.first.role
  end

  test "make_personal! requires exactly one user (not zero)" do
    account = Account.create!(name: "Empty Team", account_type: :team)

    # Team with no users cannot be made personal
    assert_not account.can_be_personal?

    account.make_personal!

    # Should remain team
    assert account.team?
  end

  # === Name Method Override Tests ===

  test "name returns owner's full name for personal accounts when available" do
    user = users(:user_1)
    account = user.personal_account

    expected_name = "#{user.full_name}'s Account"
    assert_equal expected_name, account.name
  end

  test "name falls back to stored name for personal accounts without full name" do
    user = User.create!(email_address: "nonames@example.com")
    account = user.personal_account

    # User has no first_name/last_name, so should use stored name
    assert_equal account.read_attribute(:name), account.name
  end

  test "name returns stored name for team accounts" do
    account = accounts(:team_account)
    stored_name = account.read_attribute(:name)

    assert_equal stored_name, account.name
  end

  # === Dynamic Name Updates ===

  test "personal account name updates when owner name changes" do
    user = users(:user_1)
    account = user.personal_account

    # Update user's name
    user.update!(password: "newpass123", password_confirmation: "newpass123")
    user.profile.update!(first_name: "Updated", last_name: "Name")

    assert_equal "Updated Name's Account", account.name
  end

  test "personal account can use custom stored name" do
    account = accounts(:personal_account)

    account.update!(name: "Writing Room")

    assert_equal "Writing Room", account.name
  end

  # === Critical Update Method Safety Tests (For the bug we fixed) ===

  test "update! methods work correctly on Account model" do
    account = accounts(:team_account)

    # Test update!
    assert_nothing_raised do
      account.update!(name: "Updated Team Name")
    end
    assert_equal "Updated Team Name", account.reload.name
  end

  test "update_column works correctly on Account model" do
    account = accounts(:team_account)
    original_updated_at = account.updated_at

    # Test update_column (should work without callbacks and not update updated_at)
    assert_nothing_raised do
      account.update_column(:name, "Column Updated Name")
    end

    account.reload
    assert_equal "Column Updated Name", account.name
    assert_equal original_updated_at.to_i, account.updated_at.to_i # Should not change updated_at
  end

  test "save! works correctly on Account model" do
    account = Account.new(name: "Save Test", account_type: :team)

    # Test save!
    assert_nothing_raised do
      account.save!
    end
    assert account.persisted?
  end

  # === Settings JSON Column Tests ===

  test "settings defaults to empty hash" do
    account = Account.create!(name: "Settings Test", account_type: :personal)
    assert_equal({}, account.settings)
  end

  test "settings can store JSON data" do
    account = Account.create!(
      name: "Settings Test",
      account_type: :team,
      settings: { theme: "dark", notifications: true }
    )

    account.reload
    assert_equal "dark", account.settings["theme"]
    assert_equal true, account.settings["notifications"]
  end

  # === is_site_admin Tests ===

  test "as_json includes is_site_admin field" do
    account = accounts(:personal_account)
    account.update_column(:is_site_admin, true)

    json = account.as_json
    assert json.key?("is_site_admin")
    assert_equal true, json["is_site_admin"]
  end

  test "as_json includes is_site_admin as false when not set" do
    account = accounts(:personal_account)
    account.update_column(:is_site_admin, false)

    json = account.as_json
    assert json.key?("is_site_admin")
    assert_equal false, json["is_site_admin"]
  end

  # === Invitation System Tests ===

  test "invite_member builds proper invitation" do
    account = accounts(:team)
    admin = users(:admin)

    invitation = account.invite_member(
      email: "newuser@example.com",
      role: "member",
      invited_by: admin
    )

    assert invitation.new_record?
    assert_equal "member", invitation.role
    assert_equal admin, invitation.invited_by
    assert invitation.invitation?
  end

  test "personal accounts cannot save invitations" do
    account = accounts(:personal)
    owner = users(:owner)

    invitation = account.invite_member(
      email: "personalcannotinvite@example.com",
      role: "member",
      invited_by: owner
    )

    # The validation runs on the account when it has invitations
    account.memberships << invitation
    assert_not account.valid?
    assert_includes account.errors[:base], "Personal accounts cannot invite members"
  end

  test "last_owner? correctly identifies single owner" do
    account = Account.create!(name: "Single Owner", account_type: :team)
    user = User.create!(email_address: "onlyowner@example.com")

    Membership.create!(
      account: account,
      user: user,
      role: "owner",
      skip_confirmation: true
    )

    assert account.last_owner?

    # Add another owner
    user2 = User.create!(email_address: "secondowner@example.com")
    Membership.create!(
      account: account,
      user: user2,
      role: "owner",
      skip_confirmation: true
    )

    assert_not account.last_owner?
  end

  test "members_count returns confirmed members only" do
    account = accounts(:team)

    # Should only count confirmed memberships
    confirmed_count = account.memberships.confirmed.count
    assert_equal confirmed_count, account.members_count
  end

  test "pending_invitations_count returns pending invitations only" do
    account = accounts(:team)

    # Create a pending invitation
    User.find_or_invite("pending@example.com")
    invitation = account.invite_member(
      email: "pending@example.com",
      role: "member",
      invited_by: users(:admin)
    )
    invitation.save!

    pending_count = account.memberships.pending_invitations.count
    assert_equal pending_count, account.pending_invitations_count
  end

  test "members_with_details includes associations" do
    account = accounts(:team)

    # This should work without N+1 queries
    members = account.members_with_details

    # Verify associations are loaded
    members.each do |member|
      # These should not trigger additional queries
      assert_not_nil member.user
      # invited_by can be nil for non-invitations
    end
  end

  # === Site Admin Authorization Tests ===

  test "site_admin users can manage any account" do
    # Create a site admin user
    site_admin = User.create!(
      email_address: "siteadmin@example.com",
      is_site_admin: true
    )

    # Test with various accounts
    personal_account = accounts(:personal_account)
    team_account = accounts(:team_account)

    # Site admin should be able to manage all accounts
    assert personal_account.manageable_by?(site_admin)
    assert team_account.manageable_by?(site_admin)

    # Even accounts they're not a member of
    unrelated_account = Account.create!(name: "Unrelated", account_type: :team)
    assert unrelated_account.manageable_by?(site_admin)
  end

  test "site_admin users can access any account" do
    site_admin = User.create!(
      email_address: "siteadmin-access@example.com",
      is_site_admin: true
    )

    personal_account = accounts(:personal_account)
    team_account = accounts(:team_account)

    # Site admin should be able to access all accounts
    assert personal_account.accessible_by?(site_admin)
    assert team_account.accessible_by?(site_admin)
  end

  test "site_admin users are considered owners of any account" do
    site_admin = User.create!(
      email_address: "siteadmin-owner@example.com",
      is_site_admin: true
    )

    personal_account = accounts(:personal_account)
    team_account = accounts(:team_account)

    # Site admin should be considered owner of all accounts
    assert personal_account.owned_by?(site_admin)
    assert team_account.owned_by?(site_admin)
  end

  test "users in site_admin accounts can manage any account" do
    # Create a site admin account
    admin_account = Account.create!(
      name: "Admin Account",
      account_type: :team,
      is_site_admin: true
    )

    # Create a regular user who is a member of the admin account
    regular_user = User.create!(email_address: "regular-in-admin@example.com")
    admin_account.add_user!(regular_user, role: "member", skip_confirmation: true)

    # This user should now have site_admin privileges
    assert regular_user.site_admin

    # And should be able to manage any account
    personal_account = accounts(:personal_account)
    team_account = accounts(:team_account)

    assert personal_account.manageable_by?(regular_user)
    assert team_account.manageable_by?(regular_user)
    assert personal_account.accessible_by?(regular_user)
    assert team_account.accessible_by?(regular_user)
    assert personal_account.owned_by?(regular_user)
    assert team_account.owned_by?(regular_user)
  end

  test "non-site_admin users cannot manage accounts they're not admins of" do
    regular_user = User.create!(email_address: "regular-nonadmin@example.com")

    # User is not a member of any account
    personal_account = accounts(:personal_account)
    team_account = accounts(:team_account)

    assert_not personal_account.manageable_by?(regular_user)
    assert_not team_account.manageable_by?(regular_user)
    assert_not personal_account.accessible_by?(regular_user)
    assert_not team_account.accessible_by?(regular_user)
    assert_not personal_account.owned_by?(regular_user)
    assert_not team_account.owned_by?(regular_user)
  end

  test "authorization methods handle nil user gracefully" do
    account = accounts(:team_account)

    assert_not account.manageable_by?(nil)
    assert_not account.accessible_by?(nil)
    assert_not account.owned_by?(nil)
  end

end
