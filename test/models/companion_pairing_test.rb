require "test_helper"

class CompanionPairingTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @owner = users(:user_1)
    @offer = [ { "volume" => "darwin-volume:main", "label" => "Main disk", "access" => "write" },
      { "volume" => "darwin-volume:usb", "label" => "Backup", "access" => "read" } ]
  end

  def open_pairing(volumes: @offer)
    CompanionPairing.open!(name: "Paulina's Mac", device_request_id: "pair-abc", volumes: volumes)
  end

  test "opening stores only digests and gives a readable code and a poll secret" do
    pairing, code, secret = open_pairing
    assert_match(/\A[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}\z/, code)
    assert_match CompanionPairing::SECRET, secret
    assert_not_includes pairing.attributes.values.map(&:to_s).join, code.delete("-")
    assert_not_includes pairing.attributes.values.map(&:to_s).join, secret
    assert_equal pairing, CompanionPairing.find_pending_by_code(code.downcase.tr("-", " "))
    assert_in_delta 15.minutes.from_now, pairing.expires_at, 5
  end

  test "malformed offers are refused" do
    [ [], nil, [ { "volume" => "x", "access" => "read" } ],
      [ { "volume" => "x", "label" => "X", "access" => "admin" } ],
      [ { "volume" => "x", "label" => "X", "access" => "read" }, { "volume" => "x", "label" => "Y", "access" => "read" } ],
      Array.new(17) { |i| { "volume" => "v#{i}", "label" => "V", "access" => "read" } } ].each do |volumes|
      assert_raises(CompanionPairing::Invalid) { open_pairing(volumes: volumes) }
    end
    assert_raises(CompanionPairing::Invalid) do
      CompanionPairing.open!(name: "bad\nname", device_request_id: "pair-abc", volumes: @offer)
    end
    assert_raises(CompanionPairing::Invalid) do
      CompanionPairing.open!(name: "Mac", device_request_id: "has space", volumes: @offer)
    end
  end

  test "approval makes a grant within the offer and hands the token over until it is used" do
    pairing, _code, secret = open_pairing
    assert_equal [ :pending ], CompanionPairing.claim(pairing.to_param, secret)
    grant = pairing.approve!(account: @account, user: @owner, agents: [ @agent ],
      accesses: { "darwin-volume:main" => "write", "darwin-volume:usb" => "off" })
    assert_equal({ "residents" => [ { "id" => @agent.to_param,
      "volumes" => [ { "volume" => "darwin-volume:main", "access" => "write" } ], "execute" => false } ] }, grant.policy)
    assert_equal "pair-abc", grant.device_request_id
    state, payload = CompanionPairing.claim(pairing.to_param, secret)
    assert_equal :approved, state
    assert_equal [ @agent.to_param ], payload["resident_ids"]
    assert_equal payload, CompanionPairing.claim(pairing.to_param, secret).last, "a lost response can be collected again"
    assert_not_includes pairing.reload.ciphertext_for(:enrollment_token), payload["enrollment_token"]

    device, = CompanionEnrollmentGrant.enroll!(payload["enrollment_token"], "pair-abc")
    assert_equal @account, device.account
    assert_equal [ :expired ], CompanionPairing.claim(pairing.to_param, secret)
    assert_nil pairing.reload.enrollment_token
    assert AuditLog.exists?(action: "companion.pairing.approved", account: @account, user: @owner)
  end

  test "approval never goes above the offer, needs a resident and a disk, and happens once" do
    pairing, = open_pairing
    assert_raises(CompanionPairing::Invalid) do
      pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "darwin-volume:usb" => "write" })
    end
    assert_raises(CompanionPairing::Invalid) do
      pairing.approve!(account: @account, user: @owner, agents: [], accesses: { "darwin-volume:main" => "read" })
    end
    assert_raises(CompanionPairing::Invalid) do
      pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: {})
    end
    assert_raises(CompanionPairing::Invalid) do
      pairing.approve!(account: @account, user: @owner, agents: [ agents(:other_account_agent) ],
        accesses: { "darwin-volume:main" => "read" })
    end
    assert_nil pairing.reload.approved_at
    pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "darwin-volume:main" => "read" })
    assert_raises(CompanionPairing::Invalid) do
      pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "darwin-volume:main" => "read" })
    end
    assert_nil CompanionPairing.find_pending_by_code("anything")
  end

  test "an expired pairing can't be found or approved, and a wrong secret gets nothing" do
    pairing, code, secret = open_pairing
    assert_nil CompanionPairing.claim(pairing.to_param, "shcp_#{'A' * 43}")
    assert_nil CompanionPairing.claim("123", secret)
    travel 15.minutes + 1.second
    assert_nil CompanionPairing.find_pending_by_code(code)
    assert_equal [ :expired ], CompanionPairing.claim(pairing.to_param, secret)
    assert_raises(CompanionPairing::Invalid) do
      pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "darwin-volume:main" => "read" })
    end
  end

  test "the sweep removes abandoned and used rendezvous data and keeps live approvals" do
    abandoned, = open_pairing
    used, = open_pairing
    live, = open_pairing
    unpolled, = open_pairing
    used_grant = used.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "darwin-volume:main" => "read" })
    CompanionEnrollmentGrant.enroll!(used.reload.enrollment_token, "pair-abc")
    live.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "darwin-volume:main" => "read" })
    unpolled_grant = unpolled.approve!(account: @account, user: @owner, agents: [ @agent ],
      accesses: { "darwin-volume:main" => "read" })
    CompanionEnrollmentGrant.where(id: unpolled_grant.id).update_all(expires_at: 1.minute.ago)
    abandoned.update_column(:expires_at, 2.hours.ago)

    CompanionSweepJob.perform_now

    assert_equal [ live.id ], CompanionPairing.where(id: [ abandoned, used, live, unpolled ].map(&:id)).pluck(:id)
    assert CompanionEnrollmentGrant.exists?(used_grant.id)
    assert CompanionEnrollmentGrant.exists?(unpolled_grant.id)
    assert_equal 3, AuditLog.where(action: "companion.pairing.approved").count
  end

  test "error reporting filters pairing credentials" do
    keys = YAML.load_file(Rails.root.join("config/honeybadger.yml")).dig("request", "filter_keys")
    assert_empty %w[code poll_secret enrollment_token] - keys
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ "code" => "[FILTERED]", "poll_secret" => "[FILTERED]", "enrollment_token" => "[FILTERED]" },
      filter.filter("code" => "MARKER", "poll_secret" => "MARKER", "enrollment_token" => "MARKER"))
  end

end
