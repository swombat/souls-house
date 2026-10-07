require "test_helper"

# Comprehensive tests for the JsonAttributes concern
# Tests all key functionality including:
# - Default method inclusion and boolean field conversion
# - Enhancement blocks with context propagation
# - Nested association handling with json_attributes inheritance
# - ID obfuscation behavior (documents current bug)
# - Option merging and runtime overrides
# - Real-world usage patterns with Account, User, and Membership models
class JsonAttributesTest < ActiveSupport::TestCase

  # Helper method to get users without ObfuscatesId interference
  def get_user(id)
    User.where(id: id).first
  end

  # === Basic Configuration Tests ===

  test "json_attributes sets default methods for serialization" do
    account = accounts(:personal_account)

    json = account.as_json

    # Should include all configured attributes
    assert json.key?("personal")  # personal? becomes personal
    assert json.key?("team")      # team? becomes team
    assert json.key?("active")    # active? becomes active
    assert json.key?("is_site_admin")
    assert json.key?("name")
  end

  test "json_attributes respects except option" do
    user = users(:user_1)

    json = user.as_json

    # Should include configured methods
    assert json.key?("full_name")
    assert json.key?("site_admin")

    # Should exclude password_digest due to except option
    assert_not json.key?("password_digest")
  end

  test "json_attributes includes associations when configured" do
    membership = Membership.find(13) # invited member with invited_by

    json = membership.as_json

    # Should include nested associations
    assert json.key?("user"), "JSON should have 'user' key. Keys: #{json.keys.inspect}"
    assert json.key?("invited_by"), "JSON should have 'invited_by' key. Keys: #{json.keys.inspect}"

    # Nested user should have limited fields
    user_json = json["user"]
    assert user_json.key?("id")
    assert user_json.key?("email_address")
    assert user_json.key?("full_name")

    # Should not include excluded fields from nested models
    assert_not user_json.key?("password_digest")
  end

  # === Boolean Field Conversion Tests ===

  test "clean_boolean_keys converts question mark methods to clean names" do
    account = accounts(:personal_account)

    json = account.as_json

    # Methods ending with ? should have clean keys
    assert json.key?("personal")    # from personal?
    assert json.key?("team")        # from team?
    assert json.key?("active")      # from active?
    assert_not json.key?("personal?")
    assert_not json.key?("team?")
    assert_not json.key?("active?")
  end

  test "clean_boolean_keys preserves non-boolean method names" do
    account = accounts(:personal_account)

    json = account.as_json

    # Non-boolean methods should keep their original names
    assert json.key?("name")
    assert json.key?("is_site_admin")
    assert_not json.key?("name?")
    assert_not json.key?("is_site_admin?")
  end

  # === ID Obfuscation Tests ===

  test "serializable_hash uses to_param for id obfuscation" do
    account = accounts(:personal_account)

    json = account.as_json

    # ID should be obfuscated via to_param
    assert_equal account.to_param, json["id"]
    assert_kind_of String, json["id"]
  end

  test "as_json and serializable_hash both have same id behavior" do
    user = users(:user_1)

    json_as_json = user.as_json
    json_serializable = user.serializable_hash

    # Both should have the same ID behavior (obfuscated via to_param)
    assert_equal json_as_json["id"], json_serializable["id"]
    assert_equal user.to_param, json_as_json["id"]
    assert_kind_of String, json_as_json["id"]
    assert_kind_of String, json_serializable["id"]
  end

  # === Enhancement Block Tests ===

  test "enhancement block adds dynamic fields with context" do
    # Use real data: member membership and admin who can manage
    membership = Membership.find(13) # invited member (user 2, account 3)
    admin_user = get_user(1) # admin of account 3

    json = membership.as_json(current_user: admin_user)

    # Should include can_remove field added by the enhancement block (as symbol)
    assert json.key?(:can_remove), "JSON should have :can_remove key. Keys: #{json.keys.inspect}"
    # Admin should be able to remove regular member
    assert json[:can_remove], "Expected can_remove to be true, got: #{json[:can_remove].inspect}"
  end

  test "enhancement block receives hash and options parameters" do
    membership = Membership.find(1) # confirmed owner

    # Create a test to verify the block receives the right parameters
    original_enhancer = Membership.json_enhancer

    block_called = false
    received_hash = nil
    received_options = nil

    # Temporarily replace the enhancer to capture parameters
    Membership.instance_variable_set(:@json_enhancer, proc do |hash, options|
      block_called = true
      received_hash = hash
      received_options = options
    end)

    test_options = { current_user: get_user(1), test_param: "test_value" }
    membership.as_json(test_options)

    # Restore original enhancer
    Membership.instance_variable_set(:@json_enhancer, original_enhancer)

    assert block_called
    assert_kind_of Hash, received_hash
    assert_equal test_options[:test_param], received_options[:test_param]
    assert_equal test_options[:current_user], received_options[:current_user]
  end

  test "enhancement block does not run when no current_user provided" do
    membership = Membership.find(13) # invited member

    json = membership.as_json

    # Should not include can_remove when no current_user context
    assert_not json.key?(:can_remove)
  end

  # === Context Propagation Tests ===

  test "context options propagate to nested associations" do
    # Create a test model with nested associations to verify context propagation
    membership = Membership.find(18) # confirmed member
    admin_user = get_user(9) # owner

    # Temporarily modify User to have an enhancement block that uses current_user
    original_user_enhancer = User.json_enhancer

    User.instance_variable_set(:@json_enhancer, proc do |hash, options|
      hash[:received_current_user] = options[:current_user]&.id if options && options[:current_user]
    end)

    json = membership.as_json(current_user: admin_user)

    # The nested user should have received the current_user context
    user_json = json["user"]
    assert_equal admin_user.id, user_json[:received_current_user]

    # Restore original enhancer
    User.instance_variable_set(:@json_enhancer, original_user_enhancer)
  end

  test "extract_context_options properly extracts propagatable options" do
    account = accounts(:personal_account)
    admin_user = get_user(1) # owner of account 1

    # Test that context options are extracted correctly
    options = {
      current_user: admin_user,
      scope: "test_scope",
      context: "test_context",
      non_context_option: "should_not_propagate",
      methods: [ :extra_method ]
    }

    context = account.send(:extract_context_options, options)

    assert_equal admin_user, context[:current_user]
    assert_equal "test_scope", context[:scope]
    assert_equal "test_context", context[:context]
    assert_not context.key?(:non_context_option)
    assert_not context.key?(:methods)
  end

  # === Nested Association Handling Tests ===

  test "nested models use their own json_attributes configuration" do
    membership = Membership.find(13) # invited member

    json = membership.as_json

    # The nested user should only include configured attributes from User.json_attributes
    user_json = json["user"]
    assert user_json.key?("full_name")     # Configured in User
    assert user_json.key?("timezone") # In User.json_attributes
    assert user_json.key?("preferences") # Now in User.json_attributes
  end

  test "process_includes_for_nesting handles different include formats" do
    account = accounts(:personal_account)
    admin_user = get_user(1)

    # Test symbol include
    result = account.send(:process_includes_for_nesting, :users, { current_user: admin_user })
    expected = { users: { current_user: admin_user } }
    assert_equal expected, result

    # Test array include
    result = account.send(:process_includes_for_nesting, [ :users, :memberships ], { current_user: admin_user })
    expected = [
      { users: { current_user: admin_user } },
      { memberships: { current_user: admin_user } }
    ]
    assert_equal expected, result

    # Test hash include
    result = account.send(:process_includes_for_nesting, { users: { methods: [ :full_name ] } }, { current_user: admin_user })
    expected = { users: { methods: [ :full_name ], current_user: admin_user } }
    assert_equal expected, result
  end

  # === Option Merging Tests ===

  test "merge_json_options properly merges array options" do
    klass = Account

    base = { methods: [ :name ], only: [ :id ], except: [ :created_at ] }
    overrides = { methods: [ :active? ], only: [ :name ], except: [ :updated_at ] }

    result = klass.merge_json_options(base, overrides)

    # Arrays should be merged with union (|) operator
    assert_equal [ :name, :active? ], result[:methods]
    assert_equal [ :id, :name ], result[:only]
    assert_equal [ :created_at, :updated_at ], result[:except]
  end

  test "merge_json_options deep merges include options" do
    klass = Account

    base = {
      include: {
        users: { methods: [ :full_name ] },
        memberships: { only: [ :role ] }
      }
    }

    overrides = {
      include: {
        users: { only: [ :email_address ] },
        sessions: { methods: [ :ip_address ] }
      }
    }

    result = klass.merge_json_options(base, overrides)

    # Should deep merge includes
    expected_include = {
      users: { methods: [ :full_name ], only: [ :email_address ] },
      memberships: { only: [ :role ] },
      sessions: { methods: [ :ip_address ] }
    }

    assert_equal expected_include, result[:include]
  end

  test "merge_json_options passes through context options" do
    klass = User

    base = { methods: [ :full_name ] }
    overrides = {
      methods: [ :site_admin ],
      current_user: users(:admin),
      scope: "test_scope"
    }

    result = klass.merge_json_options(base, overrides)

    assert_equal [ :full_name, :site_admin ], result[:methods]
    assert_equal users(:admin), result[:current_user]
    assert_equal "test_scope", result[:scope]
  end

  # === Runtime Option Override Tests ===

  test "runtime options override configured options" do
    user = users(:user_1)

    # User is configured with: :full_name, :site_admin, except: [:password_digest]
    json = user.as_json(methods: [ :email_address ], except: [ :full_name ])

    # Should merge methods (union operation)
    assert json.key?("full_name")      # From configuration
    assert json.key?("site_admin")     # From configuration
    assert json.key?("email_address")  # From runtime options

    # Should merge except (union operation)
    assert_not json.key?("password_digest") # From configuration
    # Note: full_name is still included because it's also in methods from config
  end

  test "runtime options can add additional includes" do
    account = accounts(:personal_account)

    json = account.as_json(include: { memberships: { methods: [ :status ] } })

    # Should include the requested association
    assert json.key?("memberships")

    membership_json = json["memberships"].first
    assert membership_json.key?("status")
  end

  # === Edge Cases and Error Handling ===

  test "handles nil runtime options gracefully" do
    account = accounts(:personal_account)

    assert_nothing_raised do
      json = account.as_json(nil)
      assert json.key?("name")
      assert json.key?("personal")
    end
  end

  test "handles empty runtime options gracefully" do
    user = users(:user_1)

    assert_nothing_raised do
      json = user.as_json({})
      assert json.key?("full_name")
      assert json.key?("site_admin")
    end
  end

  # === Complex Nested Association Tests ===

  test "deeply nested associations maintain json_attributes behavior" do
    membership = memberships(:team_member_user)
    admin_user = users(:admin)

    # Request membership with user and user's accounts
    json = membership.as_json(
      current_user: admin_user,
      include: {
        user: {
          include: {
            accounts: { methods: [ :active? ] }
          }
        }
      }
    )

    # Verify deep nesting works
    assert json.key?("user")
    assert json["user"].key?("accounts")

    # Nested accounts should use their json_attributes
    accounts_json = json["user"]["accounts"]
    accounts_json.each do |account_json|
      assert account_json.key?("active")  # active? becomes active
      assert account_json.key?("name")    # from Account.json_attributes
    end
  end

  # === Multiple Models Integration Tests ===

  test "Account model json_attributes work correctly" do
    account = accounts(:team_account)

    json = account.as_json

    # Test boolean conversions
    assert_equal false, json["personal"]  # team account
    assert_equal true, json["team"]       # team account

    # Test custom methods
    assert json.key?("active")
    assert json.key?("name")
    assert json.key?("is_site_admin")

    # Test ID is obfuscated via to_param
    assert_equal account.to_param, json["id"]
    assert_kind_of String, json["id"]
  end

  test "User model json_attributes work correctly" do
    user = users(:user_1)

    json = user.as_json

    # Test configured methods
    assert json.key?("full_name")
    assert_equal "Test User", json["full_name"]

    assert json.key?("site_admin")

    # Test exclusions
    assert_not json.key?("password_digest")

    # Test ID is obfuscated via to_param
    assert_equal user.to_param, json["id"]
    assert_kind_of String, json["id"]
  end

  test "Membership model json_attributes with enhancement block" do
    # Use Membership that has invited_by relationship
    membership = Membership.where.not(invited_by_id: nil).first
    admin_user = membership.invited_by

    json = membership.as_json(current_user: admin_user)

    # Test configured methods
    assert json.key?("display_name")
    assert json.key?("status")
    assert json.key?("invitation")      # invitation? becomes invitation
    assert json.key?("invitation_pending") # invitation_pending? becomes invitation_pending
    assert json.key?("email_address")
    assert json.key?("full_name")
    assert json.key?("confirmed")       # confirmed? becomes confirmed

    # Test enhancement block result (uses symbol key)
    assert json.key?(:can_remove)
    assert json[:can_remove]  # Admin can remove member

    # Test nested associations
    assert json.key?("user"), "JSON should have 'user' key. Keys: #{json.keys.inspect}"
    if membership.invited_by_id
      assert json.key?("invited_by"), "JSON should have 'invited_by' key when invited_by_id present"
    else
      assert_not json.key?("invited_by"), "JSON should not have 'invited_by' key when invited_by_id is nil"
    end
  end

  # === Context Sensitivity Tests ===

  test "can_remove field reflects actual permissions" do
    # Get member's Membership record and admin who can manage
    member_membership = Membership.find(13) # invited member (user 2, account 3)
    admin_user = get_user(1) # admin of account 3
    member_user = member_membership.user # the member user

    # Admin should be able to remove member
    json_as_admin = member_membership.as_json(current_user: admin_user)
    assert json_as_admin[:can_remove]

    # Member should not be able to remove themselves
    json_as_member = member_membership.as_json(current_user: member_user)
    assert_not json_as_member[:can_remove]
  end

  test "context propagation works with complex nested structures" do
    membership = Membership.find(18) # confirmed member
    admin_user = get_user(9) # owner

    # Request deep nesting with context
    json = membership.as_json(
      current_user: admin_user,
      include: {
        account: {
          include: {
            memberships: { methods: [ :status ] }
          }
        }
      }
    )

    # Verify context was available at all levels
    assert json.key?(:can_remove)  # Top level should have enhancement
    assert json.key?("account")

    # Nested memberships should also have access to context if they define enhancements
    nested_memberships = json["account"]["memberships"]
    assert nested_memberships.is_a?(Array)
    assert nested_memberships.all? { |au| au.key?("status") }
  end

  # === Serialization Consistency Tests ===

  test "serializable_hash and as_json produce identical results" do
    account = accounts(:personal_account)
    admin_user = users(:admin)

    options = { current_user: admin_user, methods: [ :members_count ] }

    json_as_json = account.as_json(options)
    json_serializable = account.serializable_hash(options)

    assert_equal json_as_json, json_serializable
  end

  test "json serialization is deterministic" do
    user = users(:user_1)

    json1 = user.as_json
    json2 = user.as_json

    assert_equal json1, json2
  end

  # === Include Normalization Tests ===

  test "normalize_include handles symbol includes" do
    klass = Account

    result = klass.send(:normalize_include, :users)
    expected = { users: {} }

    assert_equal expected, result
  end

  test "normalize_include handles array includes" do
    klass = Account

    result = klass.send(:normalize_include, [ :users, :memberships ])
    expected = { users: {}, memberships: {} }

    assert_equal expected, result
  end

  test "normalize_include handles mixed array includes" do
    klass = Account

    result = klass.send(:normalize_include, [ :users, { memberships: { methods: [ :status ] } } ])
    expected = { users: {}, memberships: { methods: [ :status ] } }

    assert_equal expected, result
  end

  test "normalize_include handles hash includes" do
    klass = Account

    original = { users: { methods: [ :full_name ] }, memberships: {} }
    result = klass.send(:normalize_include, original)

    assert_equal original, result
  end

  test "normalize_include handles nil and empty values" do
    klass = Account

    assert_equal({}, klass.send(:normalize_include, nil))
    assert_equal({}, klass.send(:normalize_include, {}))
    assert_equal({}, klass.send(:normalize_include, []))
    assert_equal({}, klass.send(:normalize_include, ""))
  end

  # === Real-World Usage Pattern Tests ===

  test "account serialization matches expected API response format" do
    account = accounts(:team_account)

    json = account.as_json

    # Verify expected keys are present for frontend consumption
    required_keys = %w[id name personal team active is_site_admin]
    required_keys.each do |key|
      assert json.key?(key), "Expected key '#{key}' missing from account JSON"
    end

    # Verify boolean values are actual booleans
    assert [ true, false ].include?(json["personal"])
    assert [ true, false ].include?(json["team"])
    assert [ true, false ].include?(json["active"])
    assert [ true, false ].include?(json["is_site_admin"])
  end

  test "user serialization excludes sensitive data" do
    user = users(:user_1)

    json = user.as_json

    # Should include safe data
    assert json.key?("id")
    assert json.key?("full_name")
    assert json.key?("site_admin")

    # Should exclude sensitive data
    sensitive_fields = %w[password_digest confirmation_token]
    sensitive_fields.each do |field|
      assert_not json.key?(field), "Sensitive field '#{field}' should not be in JSON"
    end
  end

  test "membership serialization includes all required member management data" do
    membership = memberships(:team_member_user)
    admin_user = users(:admin)

    json = membership.as_json(current_user: admin_user)

    # Should include all fields needed for member management UI (mix of string and symbol keys)
    string_fields = %w[id display_name status invitation invitation_pending email_address full_name confirmed]
    string_fields.each do |field|
      assert json.key?(field), "Expected member field '#{field}' missing from Membership JSON"
    end

    # can_remove is added as symbol by enhancement block
    assert json.key?(:can_remove), "Expected member field 'can_remove' missing from Membership JSON"

    # Should include nested user data
    assert json.key?("user")
    assert json["user"].key?("id")
    assert json["user"].key?("email_address")
    assert json["user"].key?("full_name")
  end

  # === Performance and Edge Case Tests ===

  test "json_attributes handles large collections efficiently" do
    # Create an account with many members to test performance
    team_account = Account.create!(name: "Large Team", account_type: :team)

    # Add multiple users (but keep it reasonable for test speed)
    5.times do |i|
      user = User.create!(email_address: "member#{i}@largeteam.com")
      team_account.add_user!(user, role: "member", skip_confirmation: true)
    end

    # This should complete without errors or excessive queries
    assert_nothing_raised do
      json = team_account.as_json(include: { memberships: { include: :user } })
      assert json.key?("memberships")
      assert_equal 5, json["memberships"].length
    end
  end

  test "json_attributes with nil associations" do
    # Test Membership with nil invited_by (Rails omits nil associations)
    membership = Membership.find(1)  # Personal account membership, no invitation

    json = membership.as_json

    # Rails omits nil associations from JSON by default
    assert_not json.key?("invited_by"), "invited_by should be omitted when nil"

    # But invited Membership should have invited_by
    invited_membership = Membership.find(13)
    invited_json = invited_membership.as_json
    assert invited_json.key?("invited_by"), "invited_by should be present for invited users"
  end

  test "boolean fields handle falsy values correctly" do
    account = accounts(:personal_account)
    account.update_column(:is_site_admin, false)

    json = account.as_json

    # False should be explicitly false, not nil
    assert_equal false, json["is_site_admin"]
    assert json.key?("is_site_admin")  # Key should still be present
  end

  # === Method Resolution Tests ===

  test "json_attributes resolves methods correctly on model instances" do
    account = accounts(:personal_account)

    json = account.as_json

    # Verify that methods are called on the instance
    assert_equal account.personal?, json["personal"]
    assert_equal account.team?, json["team"]
    assert_equal account.active?, json["active"]
    assert_equal account.name, json["name"]
    assert_equal account.is_site_admin, json["is_site_admin"]
  end

  test "json_attributes handles basic serialization correctly" do
    # Create a saved account to test basic serialization
    account = Account.create!(name: "Test Serialization", account_type: :personal)

    # This should work correctly
    assert_nothing_raised do
      json = account.as_json
      # Basic fields should work
      assert json.key?("name")
      assert json.key?("personal")
      assert json.key?("id")
    end
  end

  # === Class Method Accessor Tests ===

  test "class accessors return correct configuration" do
    # Test Account configuration
    assert_equal [
      :personal?, :team?, :active?, :disabled, :is_site_admin, :name, :github_login,
      :use_system_ai_credentials
    ], Account.json_attrs
    assert_equal({}, Account.json_includes)
    assert Account.json_options.key?(:except) || Account.json_options.empty?
    assert_nil Account.json_enhancer

    # Test User configuration
    assert_equal [ :first_name, :last_name, :timezone, :full_name, :site_admin, :avatar_url, :initials, :preferences, :chat_colour ], User.json_attrs
    assert_equal({}, User.json_includes)
    assert_equal({ except: [ :password_digest, :password_reset_token, :password_reset_sent_at, :default_account_id ] }, User.json_options)
    assert_nil User.json_enhancer

    # Test Membership configuration
    expected_methods = [ :display_name, :status, :invitation?, :invitation_pending?, :email_address, :full_name, :confirmed? ]
    assert_equal expected_methods, Membership.json_attrs

    expected_includes = {
      user: { only: [ :id, :email_address ], methods: [ :full_name ] },
      invited_by: { only: [ :id ], methods: [ :full_name ] }
    }
    assert_equal expected_includes, Membership.json_includes
    assert Membership.json_enhancer.present?
  end

end
