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
    when "tweet"
      base.merge(
        author_handle: record.author_handle, kinds: record.kinds, url: record.url,
        web_path: routes.account_field_path(record.account, tab: "tweets", item: "tweet-#{record.to_param}"),
        api_path: routes.api_v1_field_tweet_path(record)
      )
    when "song"
      base.merge(
        artist: record.artist, lyrics_state: record.lyrics_state, added_by: record.added_by_name,
        suggested_by: record.suggested_by_name, shared_for: record.shared_for_name,
        web_path: routes.account_field_path(record.account, tab: "songs", item: "song-#{record.to_param}"),
        api_path: routes.api_v1_field_song_path(record)
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

  def tweet_json(tweet, tags = [])
    {
      key: "tweet-#{tweet.to_param}",
      kind: "tweet",
      id: tweet.to_param,
      title: tweet.title,
      text: tweet.text,
      author_handle: tweet.author_handle,
      author_name: tweet.author_name,
      url: tweet.url,
      kinds: tweet.kinds,
      in_reply_to_handle: tweet.in_reply_to_handle,
      in_reply_to_url: (tweet.in_reply_to_tweet_id && "https://x.com/#{tweet.in_reply_to_handle || "i"}/status/#{tweet.in_reply_to_tweet_id}"),
      related: tweet.related.presence,
      media: tweet.media,
      metrics: tweet.metrics,
      metrics_at: tweet.metrics_at&.iso8601,
      posted_at: tweet.posted_at.iso8601,
      fetched_at: tweet.fetched_at.iso8601,
      dated_at: tweet.posted_at.iso8601,
      created_at: tweet.created_at.iso8601,
      tags: tags
    }
  end

  # A song for the page. The list (`content: false`) leaves the lyrics and
  # the note behind; the open song carries everything.
  def song_json(song, tags = [], content: true)
    url_helpers = Rails.application.routes.url_helpers
    {
      key: "song-#{song.to_param}",
      kind: "song",
      id: song.to_param,
      title: song.title,
      artist: song.artist,
      album: song.album,
      year: song.year,
      links: song.links.map { |link| link.merge("label" => FieldSong::Links.label(link["provider"])) },
      lyrics: (song.lyrics if content),
      lyrics_state: song.lyrics_state,
      instrumental: song.instrumental,
      note: (content ? song.note : song.note.to_s.truncate(200).presence),
      added_by_name: song.added_by_name,
      added_by_kind: song.added_by_kind,
      suggested_by_name: song.suggested_by_name,
      suggested_by_kind: song.suggested_by_kind,
      uploader_name: song.added_by_name,
      shared_for_name: song.shared_for_name,
      shared_for_kind: song.shared_for_kind,
      shared_for_key: FieldSong.person_key(song.shared_for),
      duration_ms: song.duration_ms,
      audio: (if song.audio.attached?
                { filename: song.audio_filename, content_type: song.audio_content_type, byte_size: song.audio_byte_size,
                  url: url_helpers.rails_blob_path(song.audio, disposition: :inline, only_path: true) }
              end),
      dated_at: song.dated_at&.iso8601,
      created_at: song.created_at.iso8601,
      tags: tags
    }
  end

  # The account's tweet stream for the Field page: nil while the house has
  # streams switched off, so the page shows nothing about them.
  def tweet_stream_json(account, now: Time.current)
    return nil unless FieldTweets.enabled?

    source = account.field_tweet_source
    url_helpers = Rails.application.routes.url_helpers
    {
      refreshed_at: now.iso8601,
      source: source&.status_json(now:),
      # Who would pay: "own" (the account's TwitterAPI.io integration),
      # "house" (granted the house key) or nil (nobody yet).
      funding: FieldTweets.funding_for(account),
      integration_url: url_helpers.account_integrations_path(account, connect: "twitterapi_io"),
      house_available: FieldTweets.house_available_for?(account),
      daily_import_cap: FieldTweets.daily_import_cap,
      account_monthly_usd_ceiling: Setting.instance.field_tweets_account_monthly_usd_ceiling.to_s,
      poll_minutes: Setting.instance.field_tweets_poll_minutes
    }
  end

  def tags_json(account)
    counts = FieldTag.item_counts(account)
    account.field_tags.kept.by_name.map { |tag| { id: tag.to_param, name: tag.name, item_count: counts.fetch(tag.id, 0) } }
  end

  # The open file (`content: true`) carries its PDF pages' text, up to
  # VIEWER_PAGES pages; the Field list does not.
  VIEWER_PAGES = 50

  def file_json(file, tags = [], content: false)
    url_helpers = Rails.application.routes.url_helpers
    {
      key: "file-#{file.to_param}",
      kind: "file",
      id: file.to_param,
      title: file.title,
      note: file.note,
      summary_short: file.summary_short,
      summary_long: file.summary_long,
      summary_partial: file.summary_partial?,
      summary_pending: file.summary_pending?,
      summary_failed: file.summary_failed?,
      summary_freshness: file.summary_freshness,
      resummarize_url: url_helpers.resummarize_account_field_file_path(file.account, file),
      filename: file.filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      uploader_name: file.uploader_name,
      uploader_kind: file.uploader_kind,
      dated_at: file.dated_at&.iso8601,
      created_at: file.created_at.iso8601,
      tags: tags,
      text_extraction: file.pdf_extraction_json,
      pages: (viewer_pages(file) if content && file.pdf_readable?),
      download_url: (url_helpers.rails_blob_url(file.file, only_path: true, disposition: :attachment) if file.file.attached?)
    }
  end

  def viewer_pages(file)
    file.pages.limit(VIEWER_PAGES).map { |page| page.reader_json(text: true) }
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
      dated_at: note.dated_at&.iso8601,
      created_at: (note.last_edited_at || note.updated_at).iso8601,
      tags: tags,
      last_edited_at: note.last_edited_at&.strftime("%b %d at %l:%M %p")
    }
  end

  # content: false (the item grid) leaves the notes out; has_notes still says
  # whether there are any.
  def recording_json(recording, tags = [], content: true)
    speakers = recording.ready? ? speakers_of(recording).to_a : []
    {
      key: "recording-#{recording.to_param}",
      kind: "recording",
      id: recording.to_param,
      title: recording.title,
      note: recording.note,
      notes: (recording.notes if content),
      has_notes: recording.notes.present?,
      summary_short: recording.summary_short,
      summary_long: recording.summary_long,
      summary_pending: recording.summary_pending?,
      summary_failed: recording.summary_failed?,
      summary_freshness: recording.summary_freshness,
      resummarize_url: Rails.application.routes.url_helpers.resummarize_account_field_recording_path(recording.account, recording),
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
      speaker_names: FieldRecordingSpeaker.grouped(speakers).map { |group| group.first.display_name },
      # How many speakers still read "Speaker N", so the list can show the
      # recording is waiting for someone to name them.
      unnamed_speakers: speakers.count(&:unnamed?),
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
      ignored: speaker.ignored?,
      ignored_as: speaker.ignored? ? speaker.ignored_as : nil,
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
      ignored: speaker.ignored?,
      ignored_as: speaker.ignored? ? speaker.ignored_as : nil,
      voice_id: voice&.to_param,
      talk_ms: speaker.known_talk_ms,
      clip_start_ms: speaker.clip_start_ms,
      clip_end_ms: speaker.clip_end_ms
    }
  end

  # A voice on the Voices page. Never the print or a sample: only what was
  # learned from (counts) and whether the print may guess yet.
  def voice_page_json(voice, used_count)
    print = voice.voiceprint
    print = nil unless print&.generation == voice.print_generation
    {
      id: voice.to_param,
      name: voice.name,
      member: voice.user_id.present?,
      used_in: used_count,
      remember: voice.remember?,
      remembered: print.present?,
      recordings: print&.recording_count || 0,
      sample_seconds: (print.speech_ms / 1000 if print),
      guessing: print&.active? || false,
      learned_at: print&.updated_at&.iso8601
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
