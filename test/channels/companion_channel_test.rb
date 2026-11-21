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

  test "a ceiling report carries the Mac's run-commands opt-in when it sends one" do
    subscribe
    epoch = @device.reload.connection_epoch
    empty = { "residents" => [] }
    perform :report_ceiling, connection_epoch: epoch, ceiling: empty, execute_lifecycle_accepted: false
    assert_equal false, @device.reload.execute_lifecycle_accepted
    perform :report_ceiling, connection_epoch: epoch, ceiling: empty
    assert_nil @device.reload.execute_lifecycle_accepted
  end

  test "a clip's reply reaches the socket only under its own live epoch on an active device" do
    subscribe
    epoch = @device.reload.connection_epoch
    reply = { "type" => "reply", "submission_id" => "s", "message_id" => "m", "text" => "hi", "epoch" => epoch }

    subscription.send(:relay, reply)
    assert_equal "reply", transmissions.last["type"]

    count = transmissions.size
    subscription.send(:relay, reply.merge("epoch" => "an-older-socket"))
    assert_equal count, transmissions.size, "a reply queued for a replaced socket is dropped"

    # Queued before a pause, arriving after it: the pause ended the epoch.
    @device.apply_control!("pause")
    subscription.send(:relay, reply)
    subscription.send(:relay, reply.merge("type" => "thinking"))
    assert_equal count, transmissions.size
    subscription.send(:relay, { "type" => "pause" })
    assert_equal "pause", transmissions.last["type"], "control messages still go down"
  end

  test "a pocket's ready carries its consent, and a late consent never follows a newer one" do
    stone = pocket_device
    stub_connection current_user: nil, current_app_session: nil, current_companion_device: stone
    subscribe
    assert_equal({ "kind" => "pocket", "mic" => false, "camera" => false, "consent_revision" => 0 },
      transmissions.last.slice("kind", "mic", "camera", "consent_revision"))
    epoch = stone.reload.connection_epoch
    owner = users(:user_1)

    stone.change_capture!(capability: "mic", enabled: true, actor: owner)
    turned_on = { "type" => "consent", "mic" => true, "camera" => false, "consent_revision" => 1, "epoch" => epoch }
    stone.change_capture!(capability: "mic", enabled: false, actor: owner)
    turned_off = { "type" => "consent", "mic" => false, "camera" => false, "consent_revision" => 2, "epoch" => epoch }

    subscription.send(:relay, turned_off)
    assert_equal turned_off, transmissions.last
    count = transmissions.size
    subscription.send(:relay, turned_on)
    assert_equal count, transmissions.size, "the delayed on is dropped"
    subscription.send(:relay, turned_off.merge("epoch" => "an-older-socket"))
    assert_equal count, transmissions.size
  end

  test "audio is guarded like a reply, and a voice that finished while away follows ready" do
    stone = pocket_device
    chat = stone.chat
    agent = agents(:research_assistant)
    agent.update_column(:voice_id, "std-aria")
    submission = chat.messages.create!(role: "user", user: users(:user_1), content: "hi", suppress_automatic_dispatch: true)
    reply = chat.messages.create!(role: "assistant", agent: agent, content: "hello", suppress_automatic_dispatch: true)
    reply.voice_audio.attach(io: StringIO.new("ID3"), filename: "v.mp3", content_type: "audio/mpeg",
      metadata: { "voice_digest" => reply.current_voice_digest })
    stone.send(:record_pocket_reply!, reply, submission)

    stub_connection current_user: nil, current_app_session: nil, current_companion_device: stone
    subscribe
    epoch = stone.reload.connection_epoch
    assert_equal %w[ready audio], transmissions.map { |t| t["type"] }
    assert_equal [ submission.to_param, reply.to_param, epoch ], transmissions.last.values_at("submission_id", "message_id", "epoch")

    count = transmissions.size
    subscription.send(:relay, transmissions.last.merge("epoch" => "an-older-socket"))
    assert_equal count, transmissions.size, "audio queued for a replaced socket is dropped"
  end

  def pocket_device
    agent = agents(:research_assistant)
    pairing, _code, secret = CompanionPairing.open!(name: "The stone", device_request_id: "stone-#{SecureRandom.hex(4)}",
      volumes: nil, kind: "pocket", capabilities: %w[mic camera])
    pairing.approve!(account: agent.account, user: users(:user_1), agents: [ agent ], accesses: {})
    _state, payload = CompanionPairing.claim(pairing.to_param, secret)
    device, = CompanionEnrollmentGrant.enroll!(payload["enrollment_token"], payload["device_request_id"])
    device
  end

end
