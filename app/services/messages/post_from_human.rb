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
  # changed by edit, discard or restore. Versioned so attachments (step 4c)
  # can join the payload without reinterpreting stored digests.
  def self.submission_digest(content:)
    "v1:" + Digest::SHA256.hexdigest({ content: content.to_s }.to_json)
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
  # wake them (MessageDispatch, #94 B step 4b-ii). If any of it raises, none
  # of it exists and the error propagates. The wake is enqueued only after
  # commit; if that enqueue fails the send is still accepted and the sweeper
  # re-drives it.
  #
  # A send that needs a wake is refused before anything is written while live
  # activity is off, since there is then no durable run to reserve.
  def call(on_persisted: nil)
    message = @chat.messages.build(content: @content, user: @user, role: "user")
    if @client_message_id
      message.client_message_id = @client_message_id
      message.submission_digest = self.class.submission_digest(content: @content)
    end
    message.attachments.attach(@files) if @files.present?
    attach_audio(message) if @audio_signed_id.present?

    target_ids = @chat.mentioned_agent_ids(@content.to_s)
    if target_ids.any? && !AgentRuntimeInteraction.live_activity_enabled?
      return Result.new(status: :dispatch_unavailable, message: message)
    end

    dispatch = nil
    saved = Message.transaction do
      next false unless message.save

      on_persisted&.call(message)
      dispatch = MessageDispatch.accept!(message: message, target_agent_ids: target_ids) if target_ids.any?
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
