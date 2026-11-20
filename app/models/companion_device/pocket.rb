# A pocket device: Paulina's M5 "stone" (YZWBVe), and anything like it. It has
# no drives and runs no commands. It is bound, on its grant, to one resident
# and one conversation made for it. It can post a voice clip or a photo there,
# and it hears back only the reply to that clip.
#
# Consent (Mira, JpznZZ): the microphone and camera start off. Only the
# device's owner (the member who approved its pairing) can turn either on;
# the owner or an account admin can turn either off, pause or revoke.
#
# Provenance: one submission is open at a time. A reply goes down only when
# it is the bound resident's, written by a run of the dispatch that the
# submission's own message woke, with no other human or device message in
# between. Anything else closes the submission as ambiguous and sends
# nothing but that word.
module CompanionDevice::Pocket

  extend ActiveSupport::Concern

  KINDS = %w[computer pocket].freeze
  OPEN_WINDOW = 10.minutes
  REPLY_TEXT_LIMIT = 4_000
  MAX_CLIP_SECONDS = 60
  # Down-cable messages about a clip. Each carries the epoch it was sent
  # under, and CompanionChannel drops it at the socket unless that is still
  # the live, active connection.
  GUARDED_TYPES = %w[thinking reply ambiguous].freeze
  MEDIA = {
    "voice" => { types: %w[audio/wav audio/x-wav audio/wave audio/vnd.wave audio/webm], max: 2.megabytes, capability: "mic" },
    "photo" => { types: %w[image/jpeg], max: 1.megabyte, capability: "camera" }
  }.freeze

  # code: what the device is told; status: the HTTP status for it.
  class Refused < StandardError

    attr_reader :code, :status

    def initialize(code, status)
      @code = code
      @status = status
      super(code)
    end

  end

  class NotOwner < StandardError; end

  included do
    belongs_to :chat, optional: true
    validates :kind, inclusion: { in: KINDS }
  end

  class_methods do
    # Called once a resident's message is complete. Cheap when no pocket is
    # bound to the conversation.
    def deliver_pocket_replies(message)
      return unless message.agent_id && message.runtime_interaction_id && message.role == "assistant" &&
        !message.streaming && !message.progress_message

      where(kind: "pocket", chat_id: message.chat_id, revoked_at: nil).where.not(pocket_open_message_id: nil)
        .find_each { |device| device.deliver_pocket_reply!(message) }
    end
  end

  def pocket? = kind == "pocket"
  def computer? = kind == "computer"

  def owner_user_id = companion_enrollment_grant.created_by_user_id

  def owned_by?(user) = user.present? && owner_user_id == user.id

  def bound_resident_id = policy.fetch("residents").first&.fetch("id")

  def consent_payload = { type: "consent", mic: mic_enabled, camera: camera_enabled }

  def pocket_submission_open?(now = Time.current)
    pocket_open_message_id.present? && pocket_opened_at.present? && pocket_opened_at > now - OPEN_WINDOW
  end

  # The owner turns a capability on; the owner or a manager turns it off.
  # Audited, and pushed down the device's cable after commit.
  def change_capture!(capability:, enabled:, actor:)
    raise ArgumentError, "not a pocket device" unless pocket?
    raise ArgumentError, "unknown capability" unless CompanionPairing::CAPABILITIES.include?(capability)
    raise ArgumentError, "enabled must be a boolean" unless [ true, false ].include?(enabled)

    device = self
    with_lock do
      raise ArgumentError, "device revoked" if revoked_at
      raise ArgumentError, "#{name} doesn't have that" if enabled && !offered_capabilities.include?(capability)
      raise NotOwner if enabled && !owned_by?(actor)

      column = "#{capability}_enabled"
      before = self[column]
      return false if before == enabled

      update!(column => enabled)
      AuditLog.create!(user: actor, account: account, auditable: self, action: "companion.device.capture_changed",
        data: { device_id: obfuscated_id, capability: capability, before: before, after: enabled })
      payload = consent_payload
      ActiveRecord.after_all_transactions_commit { CompanionChannel.broadcast_to(device, payload) }
      true
    end
  end

  # Checks that need no lock, so a refused clip costs no transcription. The
  # same checks run again under the lock before anything is written.
  def pocket_precheck!(media_kind)
    spec = MEDIA[media_kind] or raise Refused.new("invalid_kind", :unprocessable_entity)
    raise Refused.new("not_pocket", :forbidden) unless pocket?
    raise Refused.new("paused", :locked) if paused?
    raise Refused.new("unauthorized", :unauthorized) unless active? && owner_still_member?
    raise Refused.new("consent_off", :forbidden) unless self["#{spec[:capability]}_enabled"]
    raise Refused.new("awaiting_reply", :conflict) if pocket_submission_open?
    spec
  end

  # Writes the message under the device lock. The caller has already stored
  # the media and, for a clip, transcribed it. Returns the Result of
  # Messages::PostFromHuman; when created, the submission is open.
  def post_pocket_submission!(media_kind:, content:, client_message_id:, files: nil, audio_signed_id: nil)
    device = self
    with_lock do
      reload
      # A retry of an accepted clip is answered before the open-slot check,
      # which that same clip is holding.
      if (existing = chat.messages.find_by(client_message_id: client_message_id, companion_device_id: id))
        return Messages::PostFromHuman::Result.new(status: :duplicate, message: existing, sole_resident: true)
      end
      pocket_precheck!(media_kind)

      result = Messages::PostFromHuman.new(chat: chat, user: companion_enrollment_grant.created_by_user,
        content: content, files: files, audio_signed_id: audio_signed_id, client_message_id: client_message_id,
        companion_device: self).call
      if result.created?
        message = result.message
        update!(pocket_open_message_id: message.id, pocket_opened_at: Time.current)
        payload = { type: "thinking", submission_id: message.to_param, epoch: connection_epoch }
        ActiveRecord.after_all_transactions_commit do
          CompanionChannel.broadcast_to(device, payload)
        end
      end
      result
    end
  end

  # One resident message, against this device's open submission.
  def deliver_pocket_reply!(reply)
    device = self
    with_lock do
      return :none unless pocket? && pocket_submission_open?
      return :inactive unless active?

      submission = chat.messages.find_by(id: pocket_open_message_id)
      return close_pocket_submission!(:ambiguous, submission) unless submission
      return :earlier unless reply.chat_id == chat_id && reply.id > submission.id
      # Another resident's message in this room says nothing about our clip.
      return :other_resident unless reply.agent&.to_param == bound_resident_id

      interaction = reply.runtime_interaction
      woken_by_submission = interaction&.message_dispatch_id.present? &&
        MessageDispatch.where(message_id: submission.id, id: interaction.message_dispatch_id).exists?
      interleaved = chat.messages.where(id: (submission.id + 1)...reply.id, role: "user").exists?
      return close_pocket_submission!(:ambiguous, submission) unless woken_by_submission && !interleaved

      update!(pocket_open_message_id: nil, pocket_opened_at: nil)
      payload = { type: "reply", submission_id: submission.to_param, message_id: reply.to_param,
        text: reply.content.to_s.truncate(REPLY_TEXT_LIMIT), epoch: connection_epoch }
      return :offline unless connection_epoch

      ActiveRecord.after_all_transactions_commit do
        # Re-read after commit: a pause or revoke that committed first wins.
        # The channel checks the epoch and the device again at the socket.
        CompanionChannel.broadcast_to(device, payload) if device.reload.active?
      end
      :delivered
    end
  end

  # A pause or revoke ends the clip in flight: nothing for it goes down later,
  # even after a resume.
  def end_pocket_submission!
    update!(pocket_open_message_id: nil, pocket_opened_at: nil) if pocket? && pocket_open_message_id
  end

  private

  def close_pocket_submission!(reason, submission)
    update!(pocket_open_message_id: nil, pocket_opened_at: nil)
    return reason unless connection_epoch

    device = self
    payload = { type: reason.to_s, submission_id: submission&.to_param, epoch: connection_epoch }
    ActiveRecord.after_all_transactions_commit { CompanionChannel.broadcast_to(device, payload) if device.reload.active? }
    reason
  end

  def owner_still_member?
    owner = companion_enrollment_grant.created_by_user
    owner.present? && owner.confirmed_memberships.exists?(account_id: account_id)
  end

end
