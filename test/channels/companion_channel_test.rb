require "test_helper"

class CompanionChannelTest < ActionCable::Channel::TestCase

  setup do
    agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: agent.account, minting_agent: agent,
      created_by_user: users(:user_1), name: "Fixture", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, = CompanionEnrollmentGrant.enroll!(grant.issue_token!(agent), "fixture")
    stub_connection current_user: nil, current_app_session: nil, current_companion_device: @device
  end

  test "device gets only its own companion channel and a new epoch" do
    subscribe
    assert subscription.confirmed?
    assert @device.reload.connection_epoch
    assert_equal "ready", transmissions.last[:type]
    unsubscribe
    assert_nil @device.reload.connection_epoch
  end

  test "all unrelated channel classes reject device before subscribed runs" do
    Rails.application.eager_load!
    classes = ApplicationCable::Channel.descendants.reject { |klass| klass == CompanionChannel || klass.name.blank? }
    assert classes.any?
    classes.each do |klass|
      channel = klass.new(connection, klass.name, {})
      channel.subscribe_to_channel
      assert channel.send(:subscription_rejected?), "#{klass.name} accepted a device"
    end
  end

  test "cookie and native app actors cannot join companion channel" do
    stub_connection current_user: users(:user_1), current_app_session: nil, current_companion_device: nil
    subscribe
    assert subscription.rejected?
  end

  test "paused devices cannot subscribe" do
    @device.update!(paused: true)
    subscribe
    assert subscription.rejected?
    assert_nil @device.reload.connection_epoch
  end

  test "replacing a live epoch records safe takeover metadata" do
    @device.update!(connection_epoch: SecureRandom.uuid)
    assert_difference -> { AuditLog.where(action: "companion.device.epoch_takeover").count } do
      subscribe
    end
    assert subscription.confirmed?
    assert_equal({ "device_id" => @device.obfuscated_id, "level" => "info" },
      AuditLog.where(action: "companion.device.epoch_takeover").last.data)
  end

  test "a ceiling report is kept from the current connection and dropped once another has taken over" do
    subscribe
    epoch = @device.reload.connection_epoch
    id = agents(:research_assistant).obfuscated_id
    first = { "residents" => [ { "id" => id, "volumes" => [ { "volume" => "Data", "access" => "write" } ] } ] }
    perform :report_ceiling, connection_epoch: epoch, ceiling: first
    assert_equal first, @device.reload.reported_ceiling
    assert_equal epoch, @device.ceiling_epoch

    # Another connection took over: this subscription's late report changes nothing.
    @device.update!(connection_epoch: "newer")
    perform :report_ceiling, connection_epoch: epoch, ceiling: { "residents" => [ { "id" => id, "volumes" => [] } ] }
    assert_equal first, @device.reload.reported_ceiling
    assert_equal epoch, @device.ceiling_epoch
    # A report never grants anything: the device's policy still has no folders.
    assert_equal [], @device.policy.dig("residents", 0, "volumes")
    assert_equal 1, @device.grant_revision
  end

end
