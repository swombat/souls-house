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
      created_at: recording.created_at.iso8601
    }
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
