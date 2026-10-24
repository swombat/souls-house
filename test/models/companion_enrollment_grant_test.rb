require "test_helper"

class CompanionEnrollmentGrantTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @grant = create_grant
  end

  test "stores only token digest and only the named home resident can mint once" do
    assert_nil @grant.issue_token!(agents(:code_reviewer))
    assert_nil @grant.issue_token!(agents(:other_account_agent))
    value = @grant.issue_token!(@agent)
    assert_match(/\Ashce_[A-Za-z0-9_-]{43}\z/, value)
    assert_equal Digest::SHA256.hexdigest(value), @grant.reload.token_digest
    assert_nil @grant.issue_token!(@agent)
    assert_nil ApiKey.authenticate(value)
  end

  test "enrollment consumes once with bounded exact-response recovery for the same request" do
    value = @grant.issue_token!(@agent)
    assert_nil CompanionEnrollmentGrant.enroll!(value, "another-request")
    assert_nil @grant.reload.consumed_at
    device, credential = CompanionEnrollmentGrant.enroll!(value, "request-1")
    assert_equal @account, device.account
    assert_equal policy, device.policy
    assert_equal 1, device.grant_revision
    assert_equal device, CompanionDevice.authenticate(credential)
    assert @grant.reload.consumed_at
    recovered_device, recovered_credential, recovered_response = CompanionEnrollmentGrant.enroll!(value, "request-1")
    assert_equal device, recovered_device
    assert_equal credential, recovered_credential
    assert_equal device.obfuscated_id, recovered_response["device_id"]
    assert_equal 1, CompanionDevice.where(companion_enrollment_grant: @grant).count
    ciphertext = @grant.ciphertext_for(:enrollment_response)
    assert_not_includes ciphertext, credential
    assert_nil CompanionEnrollmentGrant.enroll!(value, "another-request")
    travel 10.minutes + 1.second
    assert_nil CompanionEnrollmentGrant.enroll!(value, "request-1")
    assert_nil ApiKey.authenticate(credential)
  end

  test "enrollment recovery is refused after device revocation" do
    value = @grant.issue_token!(@agent)
    device, = CompanionEnrollmentGrant.enroll!(value, "request-1")
    device.revoke!
    assert_nil CompanionEnrollmentGrant.enroll!(value, "request-1")
  end

  test "expires before either minting or consuming" do
    value = @grant.issue_token!(@agent)
    unminted = create_grant
    travel 2.hours
    assert_nil unminted.issue_token!(@agent)
    assert_nil CompanionEnrollmentGrant.enroll!(value, "request-1")
  end

  test "disabled accounts cannot mint or enroll" do
    value = @grant.issue_token!(@agent)
    unminted = create_grant
    @account.update_columns(disabled_at: Time.current)
    assert_nil unminted.issue_token!(@agent)
    assert_nil CompanionEnrollmentGrant.enroll!(value, "request-1")
  end

  test "policy rejects foreign raw and malformed resident ids and unknown fields" do
    [
      policy.tap { |p| p["residents"][0]["id"] = agents(:other_account_agent).obfuscated_id },
      policy.tap { |p| p["residents"][0]["id"] = @agent.id.to_s },
      policy.tap { |p| p["residents"][0]["id"] = [] },
      policy.tap { |p| p["residents"][0]["execute"] = "false" },
      policy.tap { |p| p["residents"][0]["admin"] = true },
      policy.tap { |p| p["residents"][0]["volumes"][0]["access"] = "execute" },
      policy.tap { |p| p["residents"][0]["volumes"][0]["volume"] = "x" * 129 },
      policy.merge("anything" => true), { "residents" => [] }, []
    ].each do |invalid|
      assert_raises(CompanionEnrollmentGrant::InvalidPolicy) do
        CompanionEnrollmentGrant.normalize_policy(@account, invalid)
      end
    end
  end

  test "policy bounds residents and total volumes and rejects duplicates" do
    too_many = policy.tap { |p| p["residents"] *= 129 }
    too_many_volumes = policy.tap do |p|
      p["residents"][0]["volumes"] = 129.times.map { |i| { "volume" => "volume-#{i}", "access" => "read" } }
    end
    duplicate_volume = policy.tap { |p| p["residents"][0]["volumes"] *= 2 }
    duplicate_resident = policy.tap { |p| p["residents"] *= 2 }
    [ too_many, too_many_volumes, duplicate_volume, duplicate_resident ].each do |invalid|
      assert_raises(CompanionEnrollmentGrant::InvalidPolicy) do
        CompanionEnrollmentGrant.normalize_policy(@account, invalid)
      end
    end
  end

  test "grant strings expiry and minting account are bounded" do
    [
      { name: "x" * 101 }, { device_request_id: "x" * 129 },
      { device_request_id: "bad\nid" }, { expires_at: 25.hours.from_now },
      { expires_at: 1.minute.ago }, { minting_agent: agents(:other_account_agent) }
    ].each do |attributes|
      grant = @grant.dup
      grant.assign_attributes(attributes)
      assert_not grant.valid?, attributes.inspect
    end
  end

  private

  def policy
    { "residents" => [ { "id" => @agent.obfuscated_id,
      "volumes" => [ { "volume" => "opaque-home", "access" => "read" } ], "execute" => false } ] }
  end

  def create_grant
    CompanionEnrollmentGrant.create!(account: @account, minting_agent: @agent,
      created_by_user: users(:user_1), device_request_id: "request-1",
      name: "Synthetic companion", policy: policy, expires_at: 1.hour.from_now)
  end

end
