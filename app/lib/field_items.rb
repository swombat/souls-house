# Shared JSON shapes for Field items on the web page.
module FieldItems

  module_function

  # One FieldSearch result, the same for the API and the page: what it is,
  # when, its tags, the excerpts, and where to read the whole thing.
  def search_result_json(result)
    record = result.record
    routes = Rails.application.routes.url_helpers
    base = {
      key: "#{result.kind}-#{record.to_param}",
      kind: result.kind,
      id: record.to_param,
      title: result.kind == "note" ? record.name : record.title,
      date: result.date&.iso8601,
      tags: result.tags,
      excerpts: result.excerpts
    }

    case result.kind
    when "recording"
      base.merge(
        status: record.status, duration_ms: record.duration_ms, uploaded_by: record.uploader_name,
        web_path: routes.account_field_recording_path(record.account, record),
        api_path: routes.api_v1_field_recording_path(record)
      )
    when "file"
      base.merge(
        filename: record.filename, uploaded_by: record.uploader_name,
        web_path: routes.account_field_path(record.account, tab: "files", item: "file-#{record.to_param}"),
        api_path: routes.api_v1_field_file_path(record)
      )
    else
      base.merge(
        web_path: routes.account_field_path(record.account, tab: "notes", item: "note-#{record.to_param}"),
        api_path: routes.api_v1_whiteboard_path(record)
      )
    end
  end

  def tags_json(account)
    counts = FieldTag.item_counts(account)
    account.field_tags.kept.by_name.map { |tag| { id: tag.to_param, name: tag.name, item_count: counts.fetch(tag.id, 0) } }
  end

  def file_json(file, tags = [])
    url_helpers = Rails.application.routes.url_helpers
    {
      key: "file-#{file.to_param}",
      kind: "file",
      id: file.to_param,
      title: file.title,
      note: file.note,
      summary_short: file.summary_short,
      summary_long: file.summary_long,
      filename: file.filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      uploader_name: file.uploader_name,
      uploader_kind: file.uploader_kind,
      created_at: file.created_at.iso8601,
      tags: tags,
      download_url: (url_helpers.rails_blob_url(file.file, only_path: true, disposition: :attachment) if file.file.attached?)
    }
  end

  # In the Field list a note leaves its content behind (`content: false`);
  # the open note carries it.
  def note_json(note, tags = [], content: true)
    {
      key: "note-#{note.to_param}",
      kind: "note",
      id: note.to_param,
      title: note.name,
      name: note.name,
      summary: note.summary,
      content: (note.content if content),
      content_length: note.content.to_s.length,
      revision: note.revision,
      editor_name: note.editor_name,
      created_at: (note.last_edited_at || note.updated_at).iso8601,
      tags: tags,
      last_edited_at: note.last_edited_at&.strftime("%b %d at %l:%M %p")
    }
  end

  def recording_json(recording, tags = [])
    {
      key: "recording-#{recording.to_param}",
      kind: "recording",
      id: recording.to_param,
      title: recording.title,
      note: recording.note,
      summary_short: recording.summary_short,
      summary_long: recording.summary_long,
      status: recording.status,
      failure_reason: recording.failure_reason,
      duration_ms: recording.duration_ms,
      expected_speakers: recording.expected_speakers,
      filename: recording.filename,
      byte_size: recording.byte_size,
      uploader_name: recording.uploader_name,
      uploader_kind: recording.uploader_kind,
      transcript_source: recording.transcript_source,
      recorded_at: recording.recorded_at&.iso8601,
      source_path: recording.source_path,
      speaker_names: recording.ready? ? speakers_of(recording).map(&:display_name) : [],
      # Deleting after this point doesn't give the minutes back (spec §5).
      dispatched: recording.dispatch_count.positive?,
      retryable: recording.kept? && FieldRecording::RETRYABLE_STATUSES.include?(recording.status) && recording.audio.attached?,
      show_url: Rails.application.routes.url_helpers.account_field_recording_path(recording.account, recording),
      created_at: recording.created_at.iso8601,
      tags: tags
    }
  end

  def speakers_of(recording)
    recording.speakers.loaded? ? recording.speakers.sort_by(&:position) : recording.speakers.includes(:field_voice)
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
      talk_ms: speaker.known_talk_ms,
      clip_start_ms: speaker.clip_start_ms,
      clip_end_ms: speaker.clip_end_ms,
      recognition: (if speaker.recognition?
                      { name: speaker.recognised_voice.name, confidence: speaker.recognition_confidence,
                        token: speaker.recognition_token }
                    end),
      suggestion: (if speaker.suggestion?
                     { name: speaker.suggested_name, quote: speaker.suggestion_quote,
                       quote_ms: speaker.suggestion_quote_ms, generation: speaker.suggestion_generation,
                       label: "Suggested from what's said" }
                   end)
    }
  end

  # A speaker as the API gives it to a person's key: who they are named as and
  # where they talk. No recognition, no suggestion, no naming source; those
  # stay with the page's biometric and suggestion affordances.
  def plain_speaker_json(speaker)
    voice = speaker.field_voice&.kept? ? speaker.field_voice : nil
    {
      id: speaker.to_param,
      label: speaker.label,
      position: speaker.position,
      default_name: speaker.default_name,
      name: speaker.display_name,
      named: voice.present?,
      voice_id: voice&.to_param,
      talk_ms: speaker.known_talk_ms,
      clip_start_ms: speaker.clip_start_ms,
      clip_end_ms: speaker.clip_end_ms
    }
  end

  # Recognition affordances for one speaker on the transcript page (spec §9).
  # Only meaningful when both gates are open; the caller passes that in.
  def speaker_recognition_json(speaker, enabled:)
    return { can_remember: false, remembered: false, pending_enrolment: nil } unless enabled

    voice = speaker.field_voice&.kept? ? speaker.field_voice : nil
    pending = voice && speaker.enrolments.find { |e| e.status == "previewing" && !e.expired? && e.sample.attached? }
    print = voice&.voiceprint
    {
      can_remember: voice.present? && (print.nil? || !voice.remembered? ||
                                       FieldVoiceprints::Sample.clean_ms(speaker) > print.sample_ms),
      remembered: voice&.remembered? || false,
      remembering: voice.present? && speaker.enrolments.any? { |e| e.status == "dispatched" },
      pending_enrolment: (if pending
                            { id: pending.to_param, sample_ms: pending.sample_ms,
                              sample_url: Rails.application.routes.url_helpers.rails_blob_path(pending.sample, disposition: :inline, only_path: true) }
                          end)
    }
  end

  def voice_page_json(voice, used_count)
    print = voice.voiceprint
    {
      id: voice.to_param,
      name: voice.name,
      member: voice.user_id.present?,
      used_in: used_count,
      remembered: voice.remembered?,
      sample_seconds: (print.sample_ms / 1000 if print),
      remembered_at: print&.consented_at&.iso8601,
      remembered_by: (print&.consented_by.respond_to?(:full_name) ? print.consented_by.full_name.presence : nil)
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
      unlimited: account.recording_unlimited?,
      used_ms: FieldRecordingReservation.used_ms(account, now:),
      pending_ms: account.field_recording_reservations.where(state: "pending").sum(:audio_ms),
      window_days: FieldRecordingReservation::WINDOW.in_days.to_i
    }
  end

end
