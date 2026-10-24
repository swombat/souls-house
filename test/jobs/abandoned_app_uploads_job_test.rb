require "test_helper"
require "timeout"

class AbandonedAppUploadsJobTest < ActiveSupport::TestCase

  # These tests exercise actual commits and independent PostgreSQL row locks.
  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @chat = accounts(:personal_account).chats.create!(
      title: "Upload cleanup", model_id: "openrouter/auto", manual_responses: false
    )
    @blobs = []
    @now = Time.current.change(usec: 0)
  end

  teardown do
    Array(@started_chats).each { |chat| Chat.find_by(id: chat.id)&.destroy! }
    @chat.destroy!
    @blobs.each { |blob| ActiveStorage::Blob.find_by(id: blob.id)&.purge }
  end

  test "only tagged unattached uploads strictly older than a day are removed" do
    stale = upload(created_at: @now - 24.hours - 1.second)
    boundary = upload(created_at: @now - 24.hours)
    recent = upload(created_at: @now - 1.hour)
    untagged = upload(created_at: @now - 2.days, metadata: {})
    nested = upload(created_at: @now - 2.days, metadata: { "other" => { "app_upload" => {} } })
    attached = upload(created_at: @now - 2.days)
    message = send_upload(attached).message
    message.discard!

    AbandonedAppUploadsJob.perform_now(now: @now)

    assert_not ActiveStorage::Blob.exists?(stale.id)
    assert_not stale.service.exist?(stale.key)
    [ boundary, recent, untagged, nested, attached ].each do |blob|
      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
    end
    assert message.reload.attachments.attached?
  end

  test "unsent chat voice notes are kept for seven days, then removed; sent ones stay" do
    voice = ->(age) { upload(created_at: @now - age, metadata: { "voice_note" => VoiceNote.metadata_for(user: @user, account: @chat.account, chat: @chat) }) }
    expired = voice.call(7.days + 1.second)
    retryable = voice.call(2.days)
    sent = voice.call(8.days)
    message = @chat.messages.create!(role: "user", user: @user, content: "with audio")
    message.audio_recording.attach(sent)

    AbandonedAppUploadsJob.perform_now(now: @now)

    assert_not ActiveStorage::Blob.exists?(expired.id)
    assert_not expired.service.exist?(expired.key)
    [ retryable, sent ].each { |blob| assert ActiveStorage::Blob.exists?(blob.id) }
    assert message.reload.audio_recording.attached?
  end

  test "discarding a voice note that a message has just taken leaves it in place" do
    blob = upload(created_at: @now, metadata: { "voice_note" => VoiceNote.metadata_for(user: @user, account: @chat.account, chat: @chat) })
    message = @chat.messages.create!(role: "user", user: @user, content: "with audio")
    message.audio_recording.attach(blob)

    assert_nil VoiceNote.discard!(blob)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert blob.service.exist?(blob.key)

    message.audio_recording.purge
    assert_equal false, VoiceNote.discard!(blob), "a recording already gone is reported gone"
  end

  # A voice-note send locks its recording until commit (VoiceNote.lock_for_send),
  # in both send paths. Either the send holds the lock and a discard waits and
  # then finds it attached, or a discard finishes between the signed id's
  # resolution and the lock and the message keeps its text. The barriers wrap
  # the real code at those two points.
  { "a message in a chat" => :send_voice, "a new conversation" => :start_with_voice }.each do |label, sender|
    test "#{label}: a send holding its recording makes a concurrent discard wait and then leave it" do
      blob = voice_upload
      locked = Queue.new
      release = Queue.new
      original = VoiceNote.method(:lock_for_send)
      holding = lambda do |signed_id|
        held = original.call(signed_id) # the row is locked from here to the send's commit
        locked << true
        release.pop
        held
      end

      VoiceNote.stub(:lock_for_send, holding) do
        sending = Thread.new { ActiveRecord::Base.connection_pool.with_connection { send(sender, blob) } }
        Timeout.timeout(10) do
          locked.pop
          discarding = Thread.new { ActiveRecord::Base.connection_pool.with_connection { VoiceNote.discard!(blob) } }
          sleep 0.3
          assert discarding.alive?, "the discard waits for the send's lock"
          release << true
          assert sending.value.audio_recording.attached?
          assert_nil discarding.value, "after the send commits, the discard finds the recording attached"
        end
      end

      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
    end

    test "#{label}: a discard that wins between resolution and lock leaves the message its text" do
      blob = voice_upload
      resolved = Queue.new
      release = Queue.new
      original = ActiveStorage::Blob.method(:find_signed)
      resolving = lambda do |*args, **kwargs|
        found = original.call(*args, **kwargs)
        resolved << true
        release.pop
        found
      end

      message = nil
      ActiveStorage::Blob.stub(:find_signed, resolving) do
        sending = Thread.new { ActiveRecord::Base.connection_pool.with_connection { send(sender, blob) } }
        Timeout.timeout(10) do
          resolved.pop
          discarded = Thread.new { ActiveRecord::Base.connection_pool.with_connection { VoiceNote.discard!(blob) } }.value
          assert_equal true, discarded
          release << true
          message = sending.value
        end
      end

      assert message.persisted?
      assert_match "Spoken words", message.content
      assert_not message.reload.audio_recording.attached?
      assert_not ActiveStorage::Blob.exists?(blob.id)
    end
  end

  test "a bounded batch is removed and another run takes the remainder" do
    blobs = 3.times.map { upload(created_at: @now - 2.days) }
    stub_const(AbandonedAppUploadsJob, :BATCH_SIZE, 2) do
      AbandonedAppUploadsJob.perform_now(now: @now)
      assert_equal 1, ActiveStorage::Blob.where(id: blobs.map(&:id)).count
      AbandonedAppUploadsJob.perform_now(now: @now)
    end
    assert_empty ActiveStorage::Blob.where(id: blobs.map(&:id))
  end

  test "a storage deletion failure is logged without stopping the next upload" do
    blob = upload(created_at: @now - 2.days)
    neighbor = upload(created_at: @now - 2.days)
    service = blob.service
    original_delete = service.method(:delete)
    errors = []
    Rails.logger.stub(:error, ->(message) { errors << message }) do
      service.stub(:delete, lambda { |key|
        raise IOError, "private service diagnostic" if key == blob.key
        original_delete.call(key)
      }) do
        AbandonedAppUploadsJob.perform_now(now: @now)
      end
    end

    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert service.exist?(blob.key)
    assert_not ActiveStorage::Blob.exists?(neighbor.id)
    assert_not service.exist?(neighbor.key)
    assert_equal [ "[AbandonedAppUploadsJob] blob_id=#{blob.id} cleanup failed: IOError" ], errors
  ensure
    service&.delete(blob.key) if blob
  end

  test "a row deletion failure rolls back and does not stop the next upload" do
    blob = upload(created_at: @now - 2.days)
    neighbor = upload(created_at: @now - 2.days)
    variant = blob.variant_records.create!(variation_digest: SecureRandom.hex)
    errors = []

    # Reproduce a real FK failure when an old variant exists but automatic
    # variant tracking (and its before_destroy cleanup) is disabled.
    ActiveStorage.stub(:track_variants, false) do
      Rails.logger.stub(:error, ->(message) { errors << message }) do
        AbandonedAppUploadsJob.perform_now(now: @now)
      end
    end

    assert ActiveStorage::Blob.exists?(blob.id)
    assert blob.service.exist?(blob.key)
    assert_not ActiveStorage::Blob.exists?(neighbor.id)
    assert_not neighbor.service.exist?(neighbor.key)
    assert_equal [ "[AbandonedAppUploadsJob] blob_id=#{blob.id} cleanup failed: ActiveRecord::InvalidForeignKey" ], errors
  ensure
    variant&.destroy!
  end

  test "nested metadata keys cannot fill the batch and starve real abandoned uploads" do
    nested = 2.times.map do
      upload(created_at: @now - 2.days, metadata: { "other" => { "app_upload" => {} } })
    end
    abandoned = upload(created_at: @now - 2.days)

    stub_const(AbandonedAppUploadsJob, :BATCH_SIZE, 2) do
      AbandonedAppUploadsJob.perform_now(now: @now)
    end

    assert_not ActiveStorage::Blob.exists?(abandoned.id)
    nested.each do |blob|
      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
    end
  end

  test "a claim holding the blob lock is skipped and its committed attachment survives" do
    blob = upload(created_at: @now - 2.days)
    locked, release = Queue.new, Queue.new
    cleaner = nil
    claimant = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        send_upload(blob, on_persisted: ->(*) { locked << true; release.pop })
      end
    end

    Timeout.timeout(10) do
      locked.pop
      # Keep the timeout in this waiting thread, outside the job's per-row
      # rescue. A blocking sweep must fail the test, not swallow its timeout.
      cleaner = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          AbandonedAppUploadsJob.perform_now(now: @now)
        end
      end
      cleaner.value
      assert ActiveStorage::Blob.exists?(blob.id)
      release << true
      assert claimant.value.created?
    end
    AbandonedAppUploadsJob.perform_now(now: @now)
    assert ActiveStorage::Attachment.exists?(blob_id: blob.id)
    assert blob.service.exist?(blob.key)
  ensure
    release << true if release
    claimant&.join(10)
    cleaner&.join(10)
  end

  test "cleanup commits before file deletion and a previously resolved claim then refuses" do
    blob = upload(created_at: @now - 2.days)
    deleting, release = Queue.new, Queue.new
    service = blob.service
    original_delete = service.method(:delete)
    service.stub(:delete, lambda { |key|
      deleting << true
      release.pop
      original_delete.call(key)
    }) do
      cleaner = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          AbandonedAppUploadsJob.perform_now(now: @now)
        end
      end

      Timeout.timeout(10) do
        deleting.pop
        assert_not ActiveStorage::Blob.exists?(blob.id)
        assert service.exist?(blob.key), "bytes are removed only after commit"
        assert_no_difference "Message.count" do
          assert send_upload(blob).attachment_claimed?
        end
        release << true
        cleaner.value
      end
    ensure
      release << true
      cleaner&.join(10)
    end
    assert_not service.exist?(blob.key)
    assert_not ActiveStorage::Attachment.exists?(blob_id: blob.id)
  end

  private

  def stub_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end

  def upload(created_at:, metadata: nil)
    metadata ||= { "app_upload" => { "user_id" => @user.id, "chat_id" => @chat.id } }
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("orphan upload"), filename: "upload.txt", content_type: "text/plain", metadata: metadata
    )
    @blobs << blob
    blob.update_columns(created_at: created_at)
    blob
  end

  def send_upload(blob, on_persisted: nil)
    Messages::PostFromHuman.new(
      chat: @chat, user: @user, content: "Upload #{SecureRandom.hex(4)}",
      files: [ blob ], client_message_id: SecureRandom.uuid
    ).call(on_persisted: on_persisted)
  end

  def voice_upload(created_at: @now)
    upload(created_at: created_at, metadata: { "voice_note" => VoiceNote.metadata_for(user: @user, account: @chat.account, chat: @chat) })
  end

  def send_voice(blob)
    result = Messages::PostFromHuman.new(
      chat: @chat, user: @user, content: "Spoken words", audio_signed_id: blob.signed_id, client_message_id: SecureRandom.uuid
    ).call
    assert result.created?
    result.message
  end

  def start_with_voice(blob)
    chat = Chat.create_with_message!(
      { model_id: "openrouter/auto", account: @chat.account, manual_responses: true, title: "Voice opening" },
      message_content: "Spoken words", user: @user, audio_signed_id: blob.signed_id, automatic_response: false,
      agent_ids: [ @chat.account.agents.where(active: true).order(:id).first!.id ]
    )
    (@started_chats ||= []) << chat
    chat.messages.first
  end

end
