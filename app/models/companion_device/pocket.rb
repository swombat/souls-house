# A pocket device: Paulina's M5 "stone" (YZWBVe), and anything like it. It has
# no drives and runs no commands. It is bound, on its grant, to one resident
# and one conversation made for it. It can post a voice clip or a photo there,
# and it hears back only the reply to that clip.
#
# Consent (Mira, JpznZZ): the microphone and camera start off. Only the
# device's owner (the member who approved its pairing) can turn either on;
# the owner or an account admin can turn either off, pause or revoke.
#
# Provenance: one run of clips is open at a time. A clip sent while the run
# is open joins it, up to MAX_QUEUED_CLIPS outstanding, so nobody has to wait
# for the resident's turn to speak (Paulina, YEDPGJ; JkRXoj). A reply goes
# down only when it is the bound resident's, written by a run of a dispatch
# that one of the run's own clips woke, with no other human or device
# message in between. It covers the waking clip and only those other clips
# among the transcript rows the run was certainly shown, never one it can't
# be shown to have read (Mira, YrBOKp, #1083). Older unread clips end as
# ambiguous; newer ones are covered only in an unbroken run, and the rest
# stay open, a contiguous tail, for the wake they are holding. Every clip ends one way: covered by a
# reply, ambiguous, or expired OPEN_WINDOW after it was sent (the deadline
# is the oldest outstanding clip's own, never refreshed by a later one).
#
# Voice: the "reply" goes down at once, never held for audio. If the
# resident speaks through ElevenLabs here (SpeechEngine), its voice is
# rendered afterwards and an "audio" message follows, carrying the
# submission and reply ids and an authenticated, device-scoped URL
# (Api::V1::Companion::PocketAudiosController) that redirects to a
# short-lived storage link. The message is a notification, not the only way
# to the clip: after a reconnect "ready" is followed by an "audio" for every
# reply still in its window, so the firmware keys clips by submission and
# reply id and plays each once (Mira, JkRXoj). Each delivered reply keeps
# its own window; a later reply never makes an earlier voice unfetchable.
module CompanionDevice::Pocket

  extend ActiveSupport::Concern

  KINDS = %w[computer pocket].freeze
  OPEN_WINDOW = 10.minutes
  # Clips one open run may hold before the stone has to wait for a reply.
  MAX_QUEUED_CLIPS = 5
  # How long after its reply the voice stays fetchable by the device.
  AUDIO_WINDOW = 30.minutes
  REPLY_TEXT_LIMIT = 4_000
  MAX_CLIP_SECONDS = 60
  # Down-cable messages about a clip. Each carries the epoch it was sent
  # under, and CompanionChannel drops it at the socket unless that is still
  # the live, active connection.
  GUARDED_TYPES = %w[thinking reply audio ambiguous expired consent].freeze
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

    # The reply's voice is ready: tell each pocket device it was the reply
    # for. Cheap when none was.
    def announce_pocket_audio(message)
      where(kind: "pocket", revoked_at: nil).where("pocket_replies @> ?", [ { reply_id: message.id } ].to_json)
        .find_each { |device| device.announce_pocket_audio!(message) }
    end

    # The house's own address, for URLs sent down the cable from a job.
    def public_url_options
      { protocol: Rails.env.production? ? "https" : "http" }
        .merge(Rails.application.config.action_mailer.default_url_options || {})
    end
  end

  def pocket? = kind == "pocket"
  def computer? = kind == "computer"

  def owner_user_id = companion_enrollment_grant.created_by_user_id

  def owned_by?(user) = user.present? && owner_user_id == user.id

  def bound_resident_id = policy.fetch("residents").first&.fetch("id")

  # The whole current capture state, never a delta. The firmware keeps the
  # highest revision it has seen on this connection and treats capture as
  # off until one arrives; "ready" carries the same fields.
  def consent_state = { mic: mic_enabled, camera: camera_enabled, consent_revision: consent_revision }

  def pocket_submission_open?(now = Time.current)
    pocket_open_message_id.present? && pocket_opened_at.present? && pocket_opened_at > now - OPEN_WINDOW
  end

  # This device's clips in the open run, oldest first.
  def pocket_open_clips
    chat.messages.where(companion_device_id: id, role: "user").where(id: pocket_open_message_id..).order(:id)
  end

  # The replies this device was sent within AUDIO_WINDOW, oldest first, as
  # [reply message, submission message] pairs. Each keeps its voice
  # fetchable for its own window; a later reply supersedes nothing.
  def pocket_recent_replies(now = Time.current)
    return [] unless pocket?

    entries = current_pocket_reply_entries(now)
    messages = chat.messages.where(id: entries.flat_map { |e| [ e["reply_id"], e["submission_id"] ] }).index_by(&:id)
    entries.filter_map { |e| (reply = messages[e["reply_id"]]) && [ reply, messages[e["submission_id"]] ] }
  end

  # One of those replies, by its public id; nil if it isn't one.
  def pocket_reply(message_param, now = Time.current)
    pocket_recent_replies(now).find { |reply, _| reply.to_param == message_param.to_s }&.first
  end

  # The "audio" message for one reply, or nil when its voice isn't current.
  def pocket_audio_payload(reply, submission, epoch = connection_epoch)
    return nil unless epoch && reply.voice_audio_current?

    { type: "audio", submission_id: submission&.to_param, message_id: reply.to_param,
      url: Rails.application.routes.url_helpers.api_v1_companion_pocket_audio_url(reply.to_param, **self.class.public_url_options),
      epoch: epoch }
  end

  # Every current voice, for after "ready"; the firmware plays each once.
  def pocket_audio_payloads(epoch = connection_epoch)
    pocket_recent_replies.filter_map { |reply, submission| pocket_audio_payload(reply, submission, epoch) }
  end

  def announce_pocket_audio!(message)
    device = self
    with_lock do
      return :inactive unless active?
      reply, submission = pocket_recent_replies.find { |r, _| r.id == message.id }
      payload = reply && pocket_audio_payload(reply, submission)
      return :none unless payload

      ActiveRecord.after_all_transactions_commit { CompanionChannel.broadcast_to(device, payload) if device.reload.active? }
      :announced
    end
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

      update!(column => enabled, consent_revision: consent_revision + 1)
      AuditLog.create!(user: actor, account: account, auditable: self, action: "companion.device.capture_changed",
        data: { device_id: obfuscated_id, capability: capability, before: before, after: enabled })
      if connection_epoch
        payload = { type: "consent", **consent_state, epoch: connection_epoch }
        ActiveRecord.after_all_transactions_commit { CompanionChannel.broadcast_to(device, payload) }
      end
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
    raise Refused.new("awaiting_reply", :conflict) if pocket_submission_open? && pocket_open_clips.count >= MAX_QUEUED_CLIPS
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
      expire_lapsed_pocket_clips!
      pocket_precheck!(media_kind)

      result = Messages::PostFromHuman.new(chat: chat, user: companion_enrollment_grant.created_by_user,
        content: content, files: files, audio_signed_id: audio_signed_id, client_message_id: client_message_id,
        companion_device: self).call
      if result.created?
        message = result.message
        # The first clip anchors the run and its deadline; a later one joins
        # it without moving either, so a run can't be kept alive forever.
        update!(pocket_open_message_id: message.id, pocket_opened_at: Time.current) unless pocket_submission_open?
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
      return :none unless pocket?
      expire_lapsed_pocket_clips!
      return :none unless pocket_submission_open?
      return :inactive unless active?

      first = chat.messages.find_by(id: pocket_open_message_id)
      return close_pocket_submission!(:ambiguous, []) unless first
      return :earlier unless reply.chat_id == chat_id && reply.id > first.id
      # Another resident's message in this room says nothing about our clip.
      return :other_resident unless reply.agent&.to_param == bound_resident_id

      clips = pocket_open_clips.where(id: ...reply.id).to_a
      interaction = reply.runtime_interaction
      woke_id = interaction&.message_dispatch_id &&
        MessageDispatch.where(id: interaction.message_dispatch_id, message_id: clips.map(&:id)).pick(:message_id)
      submission = clips.find { |clip| clip.id == woke_id }
      # This device's own later clips are part of the run, not an interruption.
      interleaved = chat.messages.where(id: (first.id + 1)...reply.id, role: "user")
        .where("companion_device_id IS DISTINCT FROM ?", id).exists?
      return close_pocket_submission!(:ambiguous, pocket_open_clips.to_a) unless submission && !interleaved

      # A clip counts as read only when it is one of the transcript rows the
      # run was certainly shown (shown_message_ids; Mira, #1083), never by
      # inference from a cursor or a search of the text. That holds for the
      # clip that woke the run too: a bounded transcript can leave it out, and
      # then nothing can be called answered. Older clips not shown had their wake folded
      # into this one, so they end as ambiguous, never as answered. Newer
      # clips are covered only in an unbroken run after the waking clip, so
      # what stays waiting is a contiguous tail.
      shown = interaction.shown_message_ids.to_a
      return close_pocket_submission!(:ambiguous, pocket_open_clips.to_a) unless shown.include?(submission.id)

      older = clips.select { |clip| clip.id < submission.id }
      newer = pocket_open_clips.where("messages.id > ?", submission.id).to_a
      covered_newer = newer.take_while { |clip| shown.include?(clip.id) }
      covered = older.select { |clip| shown.include?(clip.id) } + [ submission ] + covered_newer
      unread_older = older - covered
      waiting = newer[covered_newer.length]
      update!(pocket_open_message_id: waiting&.id, pocket_opened_at: waiting&.created_at)
      record_pocket_reply!(reply, submission)
      announce_pocket_outcome(:ambiguous, unread_older) if unread_older.any?
      payload = { type: "reply", submission_id: submission.to_param, submission_ids: covered.map(&:to_param),
        message_id: reply.to_param,
        text: reply.content.to_s.truncate(REPLY_TEXT_LIMIT), epoch: connection_epoch }
      if connection_epoch
        # Registered before the voice, so the text always goes down first
        # and never waits on, or fails with, the audio (Mira, #1076).
        ActiveRecord.after_all_transactions_commit do
          # Re-read after commit: a pause or revoke that committed first wins.
          # The channel checks the epoch and the device again at the socket.
          CompanionChannel.broadcast_to(device, payload) if device.reload.active?
        end
      end
      render_pocket_voice(reply)
      connection_epoch ? :delivered : :offline
    end
  end

  # A pause or revoke ends the clip in flight: nothing for it goes down later,
  # even after a resume, and that includes the last reply's voice.
  def end_pocket_submission!
    return unless pocket? && (pocket_open_message_id || pocket_reply_message_id || pocket_replies.any?)

    update!(pocket_open_message_id: nil, pocket_opened_at: nil, pocket_replies: [],
      pocket_reply_message_id: nil, pocket_reply_submission_id: nil, pocket_replied_at: nil)
  end

  private

  # Asks for the reply's voice once the reply has committed, only where the
  # stone can be given one (SpeechEngine.for_pocket); GenerateVoiceJob
  # resolves the key again when it runs and announces the audio when it is
  # made. A failure to schedule it costs the voice, never the text.
  def render_pocket_voice(reply)
    account = chat.account
    # The whole decision runs after commit, isolated, so nothing about the
    # voice can roll back or hold up the text (Mira, #1076).
    ActiveRecord.after_all_transactions_commit do
      if reply.voice_available && SpeechEngine.for_pocket(account, reply.agent).available
        GenerateVoiceJob.perform_later(reply, surface: "pocket")
      end
    rescue StandardError => e
      Rails.logger.warn("[CompanionDevice] pocket voice for message #{reply.id} not scheduled: #{e.class}: #{e.message}")
    end
  end

  # The single "latest" columns count too when the list lacks them: a worker
  # still on the old code during a deploy writes only those, after the
  # migration's backfill has already run (Mira, #1083).
  def current_pocket_reply_entries(now = Time.current)
    entries = pocket_replies.to_a
    if pocket_reply_message_id && pocket_replied_at && entries.none? { |e| e["reply_id"] == pocket_reply_message_id }
      entries += [ { "reply_id" => pocket_reply_message_id, "submission_id" => pocket_reply_submission_id, "at" => pocket_replied_at.iso8601(6) } ]
    end
    entries.select { |e| Time.zone.parse(e["at"].to_s)&.after?(now - AUDIO_WINDOW) }
  end

  # The latest reply also stays in the single columns, which older readers
  # (and the audit trail) use.
  def record_pocket_reply!(reply, submission)
    now = Time.current
    entries = current_pocket_reply_entries(now) + [ { "reply_id" => reply.id, "submission_id" => submission.id, "at" => now.iso8601(6) } ]
    update!(pocket_replies: entries, pocket_reply_message_id: reply.id, pocket_reply_submission_id: submission.id, pocket_replied_at: now)
  end

  # Ends every outstanding clip with one word: ambiguous or expired. The
  # first clip stays as submission_id for firmware that reads only that.
  def close_pocket_submission!(reason, clips)
    update!(pocket_open_message_id: nil, pocket_opened_at: nil)
    announce_pocket_outcome(reason, clips)
  end

  def announce_pocket_outcome(reason, clips)
    return reason unless connection_epoch

    device = self
    payload = { type: reason.to_s, submission_id: clips.first&.to_param, submission_ids: clips.map(&:to_param),
      epoch: connection_epoch }
    ActiveRecord.after_all_transactions_commit { CompanionChannel.broadcast_to(device, payload) if device.reload.active? }
    reason
  end

  # Clips whose deadline passed with no reply end as expired, so none is left
  # showing "thinking" for ever. Runs before any new clip or reply is read.
  def expire_lapsed_pocket_clips!
    return unless pocket_open_message_id && !pocket_submission_open?

    close_pocket_submission!(:expired, pocket_open_clips.to_a)
  end

  def owner_still_member?
    owner = companion_enrollment_grant.created_by_user
    owner.present? && owner.confirmed_memberships.exists?(account_id: account_id)
  end

end
