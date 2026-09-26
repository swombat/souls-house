require "test_helper"

class DeviceStreamConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @stream = DeviceStream.create!(account: accounts(:team_account), subject_user: users(:user_1), name: "Synthetic race")
    @token = @stream.issue_credential!
    @payload = {
      "schema" => "rr.v1", "session_id" => SecureRandom.uuid, "sequence" => 0,
      "observed_at" => Time.current.iso8601(6), "rr_ms" => [ 800.0 ]
    }
  end

  teardown do
    @stream&.destroy!
  end

  test "simultaneous duplicate append produces exactly one batch" do
    results = concurrently(2) { |i| append }
    assert_equal [ :created, :ok ], results.sort
    assert_equal 1, @stream.reload.batches_count
    assert_equal 1, @stream.device_stream_batches.count
  end

  test "concurrent erase and append cannot leave resurrected payload" do
    results = concurrently(2) do |i|
      if i.zero?
        DeviceStream.find(@stream.id).erase_session!(@payload["session_id"])
        :erased
      else
        append
      end
    end
    assert_includes results, :erased
    assert_empty @stream.device_stream_batches
    assert_equal 0, @stream.reload.batches_count
    assert_equal :gone, append
  end

  test "concurrent bulk erase and append ends erased with zero payload" do
    concurrently(2) do |i|
      i.zero? ? DeviceStream.find(@stream.id).erase! : append
    end
    assert_empty @stream.device_stream_batches
    assert @stream.reload.erased_at
    assert_equal 0, @stream.batches_count
  end

  test "revoke committed while append waits is enforced on cached credential" do
    ready = Queue.new
    thread = nil
    @stream.with_lock do
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          credential = DeviceStreamCredential.authenticate(@token)
          ready << true
          begin
            DeviceStream.find(@stream.id).append!(credential, @payload)
          rescue DeviceStream::Rejected => error
            error.status
          end
        end
      end
      ready.pop
      @stream.device_stream_credentials.update_all(revoked_at: Time.current)
    end
    assert_equal :unauthorized, thread.value
    assert_empty @stream.device_stream_batches
  end

  private

  def append
    stream = DeviceStream.find(@stream.id)
    credential = stream.device_stream_credentials.first
    stream.append!(credential, @payload)
  rescue DeviceStream::Rejected => error
    error.status
  end

  def concurrently(count)
    ready, start = Queue.new, Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield i
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  end

end
