require "test_helper"

class DeviceStreamTest < ActiveSupport::TestCase

  setup do
    @stream = DeviceStream.create!(account: accounts(:team_account), subject_user: users(:user_1), name: "Synthetic RR")
    @token = @stream.issue_credential!
    @credential = DeviceStreamCredential.authenticate(@token)
    @payload = {
      "schema" => "rr.v1", "session_id" => SecureRandom.uuid, "sequence" => 0,
      "observed_at" => Time.current.iso8601(6), "rr_ms" => [ 810.546875, 798.828125 ]
    }
  end

  test "device token is hashed and never authenticates as API key" do
    assert_nil ApiKey.authenticate(@token)
    assert_not_equal @token, @credential.token_digest
    assert_nil DeviceStreamCredential.authenticate("hx_invalid")
  end

  test "immutable retry and conflicting retry" do
    assert_equal :created, @stream.append!(@credential, @payload)
    assert_equal :ok, @stream.append!(@credential, @payload)
    assert_equal 1, @stream.reload.batches_count
    error = assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload.merge("rr_ms" => [ 900 ])) }
    assert_equal :conflict, error.status
    assert_equal @payload["rr_ms"], @stream.device_stream_batches.first.rr_ms
  end

  test "canonical ordering and integer float representation retry identically" do
    payload = @payload.merge("rr_ms" => [ 800 ])
    @stream.append!(@credential, payload)
    assert_equal :ok, @stream.append!(@credential, payload.to_a.reverse.to_h.merge("rr_ms" => [ 800.0 ]))
  end

  test "sequence space is per session and accepts out of order delivery" do
    @stream.append!(@credential, @payload.merge("sequence" => 2))
    @stream.append!(@credential, @payload)
    @stream.append!(@credential, @payload.merge("session_id" => SecureRandom.uuid))
    assert_equal 3, @stream.reload.batches_count
  end

  test "erasure physically removes samples and tombstone rejects replay" do
    @stream.append!(@credential, @payload)
    @stream.erase_session!(@payload["session_id"])
    assert_equal 0, @stream.device_stream_batches.count
    assert_equal 0, @stream.reload.batches_count
    assert @stream.device_stream_sessions.first.erased_at
    error = assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
    assert_equal :gone, error.status
  end

  test "erasing a not yet uploaded session creates a tombstone" do
    @stream.erase_session!(@payload["session_id"])
    assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
  end

  test "bulk erasure revokes devices and forbids new sessions and credentials" do
    @stream.append!(@credential, @payload)
    @stream.erase!
    assert_empty @stream.device_stream_batches
    assert_nil DeviceStreamCredential.authenticate(@token)
    assert_raises(DeviceStream::Rejected) { @stream.issue_credential! }
    assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload.merge("session_id" => SecureRandom.uuid)) }
  end

  test "previously authenticated credential is rechecked under lock" do
    @stream.revoke_credential!(@credential.id)
    error = assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
    assert_equal :unauthorized, error.status
  end

  test "disabled stream and removed subject membership reject ingest" do
    @stream.update!(enabled: false)
    assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
    @stream.update!(enabled: true)
    @stream.account.memberships.find_by!(user: @stream.subject_user).update_column(:confirmed_at, nil)
    assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
    assert_not @stream.readable_by?(user: @stream.subject_user)
  end

  test "read grant does not inherit the API key owner's subject identity" do
    agent = agents(:other_account_agent)
    assert_not @stream.readable_by?(user: @stream.subject_user, agent: agent)
    @stream.configure!(user_ids: [], agent_ids: [ agent.id ], enabled: true)
    assert @stream.readable_by?(user: @stream.subject_user, agent: agent)
    @stream.configure!(user_ids: [], agent_ids: [], enabled: true)
    assert_not @stream.readable_by?(user: @stream.subject_user, agent: agent)
  end

  test "cross account readers and credentials are rejected" do
    assert_raises(DeviceStream::Rejected) do
      @stream.configure!(user_ids: [], agent_ids: [ agents(:research_assistant).id ], enabled: true)
    end
    other = DeviceStream.create!(account: @stream.account, subject_user: @stream.subject_user, name: "Other")
    assert_raises(DeviceStream::Rejected) { other.append!(@credential, @payload) }
  end

  test "strict schema and numeric limits" do
    invalid = [
      { "schema" => "ecg.v1" }, { "sequence" => -1 }, { "sequence" => "0" },
      { "session_id" => "../anything" }, { "rr_ms" => [] }, { "rr_ms" => [ nil ] },
      { "rr_ms" => [ Float::INFINITY ] }, { "rr_ms" => [ 0 ] },
      { "rr_ms" => [ 80_000 ] }, { "rr_ms" => [ 800 ] * 257 },
      { "observed_at" => "2026-09-25" }, { "observed_at" => 4 },
      { "observed_at" => 10.minutes.from_now.iso8601 }, { "extra" => true }
    ]
    invalid.each do |change|
      assert_raises(DeviceStream::Rejected, change.inspect) { @stream.append!(@credential, @payload.merge(change)) }
    end
    assert_empty @stream.device_stream_batches
  end

  test "capacity is explicit and does not discard retained data" do
    @stream.update!(batches_count: DeviceStream::MAX_BATCHES)
    error = assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
    assert_equal :payload_too_large, error.status
  end

  test "private RR and authorization fields are filtered" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      .filter({ "rr_ms" => [ 800 ], "observed_at" => "private", "HTTP_AUTHORIZATION" => @token })
    assert filtered.values.all? { |value| value == "[FILTERED]" }
  end

  test "inactive accounts and reader agents cannot keep accessing streams" do
    agent = agents(:other_account_agent)
    @stream.configure!(user_ids: [], agent_ids: [ agent.id ], enabled: true)
    agent.update!(active: false)
    assert_not @stream.readable_by?(user: @stream.subject_user, agent: agent)
    @stream.account.update_column(:disabled_at, Time.current)
    assert_not @stream.readable_by?(user: @stream.subject_user)
    assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload) }
  end

  test "rate limit admits retries without admitting new batches" do
    @stream.append!(@credential, @payload)
    session = @stream.device_stream_sessions.first
    DeviceStreamBatch.insert_all!((1..599).map { |n|
      { device_stream_session_id: session.id, sequence: n, observed_at: Time.current,
        rr_ms: [ 800 ], payload_digest: "synthetic-#{n}", created_at: Time.current, updated_at: Time.current }
    })
    @stream.update!(batches_count: 600)
    assert_equal :ok, @stream.append!(@credential, @payload)
    error = assert_raises(DeviceStream::Rejected) { @stream.append!(@credential, @payload.merge("sequence" => 600)) }
    assert_equal :too_many_requests, error.status
  end

end
