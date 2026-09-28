# The one way a human's message enters a chat (#94 B, step 3). The web
# controller calls it today and the app API will, so a message from the phone
# wakes exactly the residents a message from the browser does. Request
# concerns (auth, audit, response shape) stay with the caller.
class Messages::PostFromHuman

  Result = Struct.new(:status, :message, keyword_init: true) do
    def created? = status == :created
    def duplicate? = status == :duplicate
    def invalid? = status == :invalid
  end

  def initialize(chat:, user:, content:, files: nil, audio_signed_id: nil)
    @chat = chat
    @user = user
    @content = content
    @files = files
    @audio_signed_id = audio_signed_id
  end

  # on_persisted runs after save and before any resident is woken, so the
  # caller's audit exists even if dispatch raises, and a raising audit
  # dispatches nothing (the order the web controller had before extraction).
  def call(on_persisted: nil)
    message = @chat.messages.build(content: @content, user: @user, role: "user")
    message.attachments.attach(@files) if @files.present?
    attach_audio(message) if @audio_signed_id.present?

    if message.save
      on_persisted&.call(message)
      @chat.trigger_mentioned_agents!(message.content) if @chat.manual_responses?
      Result.new(status: :created, message: message)
    elsif message.errors.added?(:base, :duplicate_message)
      Result.new(status: :duplicate, message: message)
    else
      Result.new(status: :invalid, message: message)
    end
  end

  private

  def attach_audio(message)
    message.audio_recording.attach(@audio_signed_id)
    message.audio_source = true
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    Rails.logger.warn "Invalid audio_signed_id for message in chat #{@chat.id}"
  end

end
