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
    def attachment_claimed? = status == :attachment_claimed
  end

  # What a retry is compared against (ADR 0004): written at create and never
  # changed by edit, discard or restore. A text-only send keeps its v1 digest;
  # a send with attachments (step 4c) is v2 and also covers each file's
  # checksum, size and name in order, so a retry that re-uploaded the same
  # file still matches and a different file is a conflict. Not its content
  # type: ActiveStorage re-identifies that from the bytes when the file is
  # attached, so it can change between a send and its retry while the file
  # stays the same, and the checksum already pins the bytes. A blob that
  # can't be resolved (nil) digests as an empty slot, so it never matches.
  def self.submission_digest(content:, blobs: [])
    return "v1:" + Digest::SHA256.hexdigest({ content: content.to_s }.to_json) if blobs.empty?

    files = blobs.map { |b| b && [ b.checksum, b.byte_size, b.filename.to_s ] }
    "v2:" + Digest::SHA256.hexdigest({ content: content.to_s, attachments: files }.to_json)
  end

  # draft: the author's ConversationDraft and the revision the client sent.
  # Only the web sends one; a native send never clears a web draft.
  def initialize(chat:, user:, content:, files: nil, audio_signed_id: nil, client_message_id: nil, draft: nil, draft_revision: nil)
    @chat = chat
    @draft = draft
    @draft_revision = draft_revision
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
  # An app upload (a blob) belongs to one message only. Its claim is part of
  # the same transaction: the blobs are locked, and a send that finds one
  # already attached is refused with nothing written (attachment_claimed).
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

    # A room with one resident wakes it automatically (Message writes that
    # dispatch), so a mention there would be a second wake.
    target_ids = @chat.sole_resident ? [] : @chat.mentioned_agent_ids(@content.to_s)
    if target_ids.any? && !AgentRuntimeInteraction.live_activity_enabled?
      return Result.new(status: :dispatch_unavailable, message: message)
    end

    dispatch = nil
    saved_id = nil
    claimed = true
    saved = begin
      Message.transaction do
        next claimed = false unless claim_uploads

        next false unless @draft ? @draft.accept_send!(message, revision: @draft_revision) { message.save } : message.save

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

    if !claimed
      Result.new(status: :attachment_claimed, message: message)
    elsif saved
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

  # Locks this send's app uploads and refuses if any is already part of a
  # message; a concurrent send of the same upload waits here for this one's
  # commit and then sees its attachment. Records each file's place in the
  # submission, since the attachment rows don't keep order (#94 B, 4c).
  def claim_uploads
    blobs = app_blobs
    return true if blobs.empty?

    ids = blobs.map(&:id)
    ActiveStorage::Blob.where(id: ids).order(:id).lock.pluck(:id)
    return false if ActiveStorage::Attachment.where(blob_id: ids).exists?

    blobs.each_with_index do |blob, position|
      metadata = blob.metadata.merge("position" => position)
      blob.update_column(:metadata, metadata)
    end
    true
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
