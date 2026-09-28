# The one way a human's message enters a chat (#94 B, step 3). The web
# controller calls it today and the app API will, so a message from the phone
# wakes exactly the residents a message from the browser does. Request
# concerns (auth, audit, response shape) stay with the caller.
class Messages::PostFromHuman

  Result = Struct.new(:status, :message, keyword_init: true) do
    def created? = status == :created
    def duplicate? = status == :duplicate
    def invalid? = status == :invalid
    def dispatch_unavailable? = status == :dispatch_unavailable
  end

  # What a retry is compared against (ADR 0004): written at create and never
  # changed by edit, discard or restore. A text-only send keeps its v1 digest;
  # a send with attachments (step 4c) is v2 and also covers each file's
  # checksum, size, name and type in order, so a retry that re-uploaded the
  # same file still matches and a different file is a conflict. A blob that
  # can't be resolved (nil) digests as an empty slot, so it never matches.
  def self.submission_digest(content:, blobs: [])
    return "v1:" + Digest::SHA256.hexdigest({ content: content.to_s }.to_json) if blobs.empty?

    files = blobs.map { |b| b && [ b.checksum, b.byte_size, b.filename.to_s, b.content_type ] }
    "v2:" + Digest::SHA256.hexdigest({ content: content.to_s, attachments: files }.to_json)
  end

  def initialize(chat:, user:, content:, files: nil, audio_signed_id: nil, client_message_id: nil)
    @chat = chat
    @user = user
    @content = content
    @files = files
    @audio_signed_id = audio_signed_id
    @client_message_id = client_message_id
  end

  # Acceptance is one primary transaction: the message, the caller's audit
  # (on_persisted) and, when residents are mentioned, the durable intent to
  # wake them (MessageDispatch, #94 B step 4b-ii). If any of it raises before
  # commit, none of it exists and the error propagates. Anything that fails
  # after commit (a model's after_commit callback, or the wake's enqueue)
  # leaves the send accepted: it is logged, and the sweeper re-drives the wake.
  #
  # A send that needs a wake is refused before anything is written while live
  # activity is off, since there is then no durable run to reserve.
  def call(on_persisted: nil)
    message = @chat.messages.build(content: @content, user: @user, role: "user")
    if @client_message_id
      message.client_message_id = @client_message_id
      message.submission_digest = self.class.submission_digest(content: @content, blobs: app_blobs)
    end
    if @files.present?
      message.attachments.attach(@files)
      # A file with no caption is a message, as in Chat#create_with_message.
      message.skip_content_validation = @content.blank?
    end
    attach_audio(message) if @audio_signed_id.present?

    target_ids = @chat.mentioned_agent_ids(@content.to_s)
    if target_ids.any? && !AgentRuntimeInteraction.live_activity_enabled?
      return Result.new(status: :dispatch_unavailable, message: message)
    end

    dispatch = nil
    saved_id = nil
    saved = begin
      Message.transaction do
        next false unless message.save

        on_persisted&.call(message)
        dispatch = MessageDispatch.accept!(message: message, target_agent_ids: target_ids) if target_ids.any?
        saved_id = message.id
        true
      end
    rescue StandardError => e
      # Commit callbacks run, and can raise, after the commit. Whether this
      # send was accepted is whether its row exists, not whether we raised.
      raise unless saved_id && Message.exists?(saved_id)

      Rails.logger.warn "[PostFromHuman] message #{saved_id} accepted; an after-commit step failed: #{e.class}: #{e.message}"
      true
    end

    if saved
      enqueue(dispatch) if dispatch
      Result.new(status: :created, message: message)
    elsif message.errors.added?(:base, :duplicate_message)
      Result.new(status: :duplicate, message: message)
    else
      Result.new(status: :invalid, message: message)
    end
  end

  private

  # The digest is only written for app sends, whose files are blobs.
  def app_blobs
    Array(@files).grep(ActiveStorage::Blob)
  end

  def enqueue(dispatch)
    MessageDispatchJob.perform_later(dispatch)
  rescue StandardError => e
    Rails.logger.warn "[PostFromHuman] dispatch #{dispatch.id} enqueue failed, left for the sweeper: #{e.class}: #{e.message}"
  end

  def attach_audio(message)
    message.audio_recording.attach(@audio_signed_id)
    message.audio_source = true
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    Rails.logger.warn "Invalid audio_signed_id for message in chat #{@chat.id}"
  end

end
