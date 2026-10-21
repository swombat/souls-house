# A sample is the exact montage used for enrollment, not the transcript's
# short preview. Every read (including each media range) is account scoped.
class FieldVoiceSamplesController < ApplicationController

  # Never use Rails.cache here: production stores it in the cache database.
  # This bounded, process-local store cannot persist audio to disk or backups.
  AUDIO_CACHE = ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes, expires_in: 10.minutes)

  require_feature_enabled :agents
  before_action :set_voice
  before_action :set_speaker, except: %i[index prepare]

  # A voice can be named in hundreds of speakers; only a few have a sample.
  # The review list is the samples; the rest are a count, listed on request.
  SAMPLES_PAGE = 50
  OTHER_PAGE = 15
  STATE_ORDER = %w[review preparing not_ready removed confirmed].freeze

  def index
    return render(json: other_namings_json) if params[:scope] == "other"

    # Every sample is ordered before paging, so none in the fingerprint is
    # out of reach however many there are (Mira's review of #488).
    speakers = kept_speakers.where(id: sampled_speaker_ids)
      .includes(:field_recording, :voice_samples, :sample_confirmed_by).order(id: :desc)
    rows = speakers.map { |speaker| sample_json(speaker) }.each_with_index
      .sort_by { |row, index| [ STATE_ORDER.index(row[:state]) || STATE_ORDER.size, index ] }.map(&:first)
    pages = [ (rows.size / SAMPLES_PAGE.to_f).ceil, 1 ].max
    page = params[:page].to_i.clamp(1, pages)
    render json: {
      samples: rows.slice((page - 1) * SAMPLES_PAGE, SAMPLES_PAGE) || [],
      page:, pages:, total: rows.size,
      state_counts: rows.map { |row| row[:state] }.tally,
      other_namings: kept_speakers.where.not(id: sampled_speaker_ids).count,
      preparable: rows.count { |row| row[:state] == "not_ready" && row[:can_relearn] },
      learning: learning_state,
      print: print_state
    }
  end

  # Rebuild, in the background, every sample of this voice that can't be
  # heard yet (no recorded spans, or its source changed), so it can be played.
  def prepare
    render json: { queued: FieldVoiceprints::Learning.prepare_for_review!(@voice) }
  end

  def update
    sample = @speaker.voice_samples.find_by!(field_voice: @voice)
    included = params.require(:included)
    return head(:unprocessable_entity) unless [ true, false ].include?(included)

    saved = @speaker.review_sample!(sample:, digest: params[:digest], by: Current.user, included:)
    return render json: { error: "This sample changed. Reload, listen again and retry." }, status: :conflict unless saved

    render json: { saved: true }
  end

  def relearn
    unless @speaker.relearn_sample!
      return render json: { error: "Learning is off or this attribution needs correction in the source recording." }, status: :conflict
    end
    render json: { saved: true }
  end

  def audio
    sample = @speaker.voice_samples.find_by!(field_voice: @voice)
    return head(:conflict) unless params[:digest].present? && params[:digest] == sample.source_digest && sample.source_current?
    return head(:not_found) unless @speaker.field_recording.audio.attached?

    # Authorise and source-check every range, but reuse this exact private cut
    # for Safari's probe/chunk requests rather than downloading the source again.
    AUDIO_CACHE.cleanup
    bytes = AUDIO_CACHE.fetch(
      [ "field-voice-sample-audio-v1", current_account.id, sample.id, sample.source_digest ]
    ) do
      FieldVoiceprints::Sample.cut(@speaker.field_recording, sample.source_segments) { |path| File.binread(path) }
    end
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Accept-Ranges"] = "bytes"
    if request.headers["Range"].present?
      ranges = Rack::Utils.get_byte_ranges(request.headers["Range"], bytes.bytesize)
      unless ranges&.one?
        response.headers["Content-Range"] = "bytes */#{bytes.bytesize}"
        return head(:range_not_satisfiable)
      end
      range = ranges.first
      response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{bytes.bytesize}"
      send_data bytes.byteslice(range), type: "audio/wav", disposition: "inline", filename: "speaker-sample.wav",
        status: :partial_content
    else
      send_data bytes, type: "audio/wav", disposition: "inline", filename: "speaker-sample.wav"
    end
  rescue FieldVoiceprints::Sample::Refused, ActiveStorage::FileNotFoundError
    head :not_found
  end

  private

  def set_voice
    @voice = current_account.field_voices.kept.find_by!(id: FieldVoice.decode_id(params[:field_voice_id]))
  end

  def set_speaker
    @speaker = kept_speakers.find_by!(id: FieldRecordingSpeaker.decode_id(params[:id]))
  end

  def kept_speakers
    @voice.speakers.joins(:field_recording).merge(FieldRecording.kept)
  end

  def sampled_speaker_ids
    FieldVoiceSample.where(field_voice: @voice).select(:field_recording_speaker_id)
  end

  # Namings with no stored sample, and why, a page at a time (the reason reads
  # the transcript, so it is never computed for the whole list).
  def other_namings_json
    speakers = kept_speakers.where.not(id: sampled_speaker_ids).includes(:field_recording).order(id: :desc)
    page = [ params[:page].to_i, 1 ].max
    total = speakers.count
    {
      namings: speakers.limit(OTHER_PAGE).offset((page - 1) * OTHER_PAGE).map { |speaker|
        recording = speaker.field_recording
        { id: speaker.to_param, recording_title: recording.title, recorded_at: recording.created_at.iso8601,
          source_url: account_field_recording_path(current_account, recording), label: speaker.default_name,
          reason: unavailable_reason(speaker, nil, false), status: speaker.sample_learning_status }
      },
      page:, pages: [ (total / OTHER_PAGE.to_f).ceil, 1 ].max, total:
    }
  end

  def sample_json(speaker)
    sample = speaker.voice_samples.find { |row| row.field_voice_id == @voice.id }
    recording = speaker.field_recording
    current = sample&.source_current? || false
    confirmed = current && speaker.sample_confirmed_digest == sample.source_digest &&
      speaker.sample_confirmed_by_id.present? && speaker.sample_confirmed_at.present?
    included = sample&.eligible? == true && !speaker.sample_excluded?
    status = (speaker.sample_learning_status if learning_state == "Learning enabled" && speaker.training_label?)
    {
      id: speaker.to_param, recording_title: recording.title, recorded_at: recording.created_at.iso8601,
      source_url: account_field_recording_path(current_account, recording),
      label: speaker.default_name, naming_source: sample&.label_origin || speaker.naming_source,
      state: sample_state(included:, confirmed:, current:, status:),
      included:,
      contributing: included && sample.profile == @voice.voiceprint&.profile,
      confirmed:,
      confirmed_by: (speaker.sample_confirmed_by&.full_name if confirmed),
      confirmed_at: (speaker.sample_confirmed_at&.iso8601 if confirmed),
      segments: sample&.source_segments, duration_ms: sample&.speech_ms, digest: sample&.source_digest,
      has_sample: sample.present?, source_current: current,
      audio_url: (audio_account_field_voice_sample_path(current_account, @voice, speaker, digest: sample.source_digest) if current && recording.audio.attached?),
      unavailable: unavailable_reason(speaker, sample, current),
      status:,
      error: speaker.sample_learning_error,
      can_relearn: speaker.training_label? && learning_state == "Learning enabled"
    }
  end

  # One word per row for the review list: what, if anything, a person does next.
  def sample_state(included:, confirmed:, current:, status:)
    return "preparing" if status == "pending"
    return "removed" unless included
    return "not_ready" unless current

    confirmed ? "confirmed" : "review"
  end

  def unavailable_reason(speaker, sample, current)
    return "Source audio is missing" unless speaker.field_recording.audio.attached?
    return "Spans were not recorded. Rebuild this sample before listening and confirming." if sample && sample.source_segments.blank?
    return "Source evidence changed. Rebuild, then listen again." if sample && !current
    return nil if sample

    FieldVoiceprints::Sample.segments_for(speaker)
    "No stored sample"
  rescue FieldVoiceprints::Sample::Refused => error
    error.message
  end

  def learning_state
    @learning_state ||= if !@voice.remember? then "Learning is off for this speaker"
    elsif !current_account.recognise_voices? then "Learning is off for this account"
    elsif !FieldVoiceprints.house_enabled? then "Voice service is unavailable"
    elsif !FieldVoiceprints.learning_ready? then "Learning is waiting for naming provenance setup"
    else "Learning enabled"
    end
  end

  def print_state
    print = @voice.voiceprint
    return "No fingerprint" unless print&.current?
    return "Included samples are kept, but recognition is off" unless FieldVoiceprints.enabled_for?(current_account)
    return "Recognising: validation passed" if FieldVoiceprints::Identification.active_prints(current_account).any? { |row| row.id == print.id }
    return "Not recognising: needs samples from at least two recordings" if print.recording_count < 2
    return "Waiting for validation" if print.validated_digest.blank?

    "Not recognising: validation has not passed for the current sample set"
  end

end
