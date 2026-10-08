# Shared JSON shapes for Field items on the web page.
module FieldItems

  module_function

  def file_json(file)
    url_helpers = Rails.application.routes.url_helpers
    {
      key: "file-#{file.to_param}",
      kind: "file",
      id: file.to_param,
      title: file.title,
      note: file.note,
      filename: file.filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      uploader_name: file.uploader_name,
      uploader_kind: file.uploader_kind,
      created_at: file.created_at.iso8601,
      download_url: (url_helpers.rails_blob_url(file.file, only_path: true, disposition: :attachment) if file.file.attached?)
    }
  end

  def note_json(note)
    {
      key: "note-#{note.to_param}",
      kind: "note",
      id: note.to_param,
      title: note.name,
      name: note.name,
      summary: note.summary,
      content: note.content,
      content_length: note.content.to_s.length,
      revision: note.revision,
      editor_name: note.editor_name,
      created_at: (note.last_edited_at || note.updated_at).iso8601,
      last_edited_at: note.last_edited_at&.strftime("%b %d at %l:%M %p")
    }
  end

  def recording_json(recording)
    {
      key: "recording-#{recording.to_param}",
      kind: "recording",
      id: recording.to_param,
      title: recording.title,
      note: recording.note,
      status: recording.status,
      failure_reason: recording.failure_reason,
      duration_ms: recording.duration_ms,
      expected_speakers: recording.expected_speakers,
      filename: recording.filename,
      byte_size: recording.byte_size,
      uploader_name: recording.uploader_name,
      uploader_kind: recording.uploader_kind,
      speaker_names: recording.ready? ? recording.speakers.includes(:field_voice).map(&:display_name) : [],
      # Deleting after this point doesn't give the minutes back (spec §5).
      dispatched: recording.dispatch_count.positive?,
      retryable: recording.kept? && FieldRecording::RETRYABLE_STATUSES.include?(recording.status) && recording.audio.attached?,
      show_url: Rails.application.routes.url_helpers.account_field_recording_path(recording.account, recording),
      created_at: recording.created_at.iso8601
    }
  end

  def speaker_json(speaker)
    {
      id: speaker.to_param,
      label: speaker.label,
      position: speaker.position,
      default_name: speaker.default_name,
      name: speaker.display_name,
      named: speaker.field_voice&.kept? || false,
      voice_id: speaker.field_voice&.kept? ? speaker.field_voice.to_param : nil,
      naming_source: speaker.naming_source,
      talk_ms: speaker.talk_ms,
      clip_start_ms: speaker.clip_start_ms,
      clip_end_ms: speaker.clip_end_ms,
      suggestion: (if speaker.suggestion?
                     { name: speaker.suggested_name, quote: speaker.suggestion_quote,
                       quote_ms: speaker.suggestion_quote_ms, generation: speaker.suggestion_generation,
                       label: "Suggested from what's said" }
                   end)
    }
  end

  # Voices for the "Who's this?" chip, most recently named first.
  def voices_json(account)
    last_named = FieldRecordingSpeaker.where(field_voice_id: account.field_voices.kept.select(:id))
      .group(:field_voice_id).maximum(:named_at)
    account.field_voices.kept.includes(:user)
      .sort_by { |voice| [ -(last_named[voice.id]&.to_f || 0), voice.name.downcase ] }
      .map { |voice| { id: voice.to_param, name: voice.name, member: voice.user_id.present? } }
  end

  # Members who could be picked by name. The current user is never listed:
  # they're always offered as "You".
  def members_without_voice_json(account, except: nil)
    voiced = account.field_voices.kept.where.not(user_id: nil).pluck(:user_id)
    account.users.where.not(id: voiced).where.not(id: except&.id).order(:id).map do |user|
      { user_id: user.id, name: user.full_name.presence || user.email_address.split("@").first }
    end
  end

  # The gauge (spec §6): used over the rolling 7 days, with the part still
  # transcribing shown separately.
  def allowance_json(account, now: Time.current)
    {
      limit_ms: account.recording_ms_weekly_limit,
      used_ms: FieldRecordingReservation.used_ms(account, now:),
      pending_ms: account.field_recording_reservations.where(state: "pending").sum(:audio_ms),
      window_days: FieldRecordingReservation::WINDOW.in_days.to_i
    }
  end

end
