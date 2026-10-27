# A sample is the exact montage used for enrollment, not the transcript's
# short preview. Every read (including each media range) is account scoped.
class FieldVoiceSamplesController < ApplicationController

  require_feature_enabled :agents
  before_action :set_voice
  before_action :set_speaker, except: %i[index prepare warm]
  rescue_from FieldVoiceprints::Limits::Reached, FieldVoiceSamples::Conflict do |error|
    render json: { error: error.message }, status: :conflict
  end
  rescue_from FieldVoiceSamples::Invalid do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end

  # A voice can be named in hundreds of speakers; only a few have a sample.
  # The review list is the samples; the rest are a count, listed on request.
  SAMPLES_PAGE = 50
  OTHER_PAGE = 15
  STATE_ORDER = %w[review preparing not_ready removed confirmed spare].freeze

  def index
    return render(json: other_namings_json) if params[:scope] == "other"

    # Every sample is ordered before paging, so none in the fingerprint is
    # out of reach however many there are (Mira's review of #488).
    speakers = kept_speakers.where(id: sampled_speaker_ids)
      .includes(:field_recording, :voice_samples, :sample_confirmed_by).order(id: :desc)
    rows = (speakers.map { |speaker| sample_json(speaker) } + uploaded_rows).each_with_index
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
      print: print_state,
      full: full?
    }
  end

  # Rebuild, in the background, every sample of this voice that can't be
  # heard yet (no recorded spans, or its source changed), so it can be played.
  def prepare
    render json: { queued: FieldVoiceprints::Learning.prepare_for_review!(@voice) }
  end

  # Cut, in the background, the samples the page is about to play, so Play
  # starts at once instead of waiting for a long recording to be fetched and
  # decoded. Only this voice's current samples with source audio.
  def warm
    ids = Array(params[:ids]).map(&:to_s).reject { |id| id.start_with?("upload-") }.first(FieldVoiceSamples::Audio::WARM_LIMIT)
    speaker_ids = ids.filter_map { |id| FieldRecordingSpeaker.decode_id(id) }
    speakers = kept_speakers.where(id: speaker_ids).includes(:voice_samples, field_recording: { audio_attachment: :blob })
      .index_by(&:id)
    pairs = speaker_ids.filter_map do |id|
      speaker = speakers[id]
      sample = speaker&.voice_samples&.find { |row| row.field_voice_id == @voice.id && row.removed_at.nil? }
      next unless sample&.source_current? && sample.source_segments.present? && speaker.field_recording.audio.attached?

      [ speaker, sample ]
    end
    render json: { warming: FieldVoiceSamples::Audio.warm(current_account, pairs) }
  end

  def update
    if @uploaded_sample
      @uploaded_sample.review!(digest: params[:digest], by: Current.user, included: params[:included])
      return render json: { saved: true }
    end
    sample = @speaker.voice_samples.find_by!(field_voice: @voice)
    included = params.require(:included)
    return head(:unprocessable_entity) unless [ true, false ].include?(included)

    saved = @speaker.review_sample!(sample:, digest: params[:digest], by: Current.user, included:)
    return render json: { error: "This sample changed. Reload, listen again and retry." }, status: :conflict unless saved

    render json: { saved: true }
  end

  def relearn
    return head :unprocessable_entity if @uploaded_sample

    unless @speaker.relearn_sample!
      return render json: { error: "Learning is off or this attribution needs correction in the source recording." }, status: :conflict
    end
    render json: { saved: true }
  end

  def audio
    if @uploaded_sample
      unless params[:digest].present? && params[:digest] == @uploaded_sample.source_digest && @uploaded_sample.source_current?
        return head :conflict
      end
      response.headers["Cache-Control"] = "private, no-store"
      return send_data @uploaded_sample.audio.download, type: "audio/wav", disposition: "inline", filename: "voice-sample.wav"
    end
    sample = @speaker.voice_samples.find_by!(field_voice: @voice)
    return head(:conflict) unless params[:digest].present? && params[:digest] == sample.source_digest && sample.source_current?
    return head(:not_found) unless @speaker.field_recording.audio.attached?

    # Authorise and source-check every range, but reuse this exact private cut
    # (process memory only, FieldVoiceSamples::Audio) for Safari's probe/chunk
    # requests and for cuts made ahead by #warm.
    bytes = FieldVoiceSamples::Audio.bytes(current_account, @speaker, sample)
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
    if params[:id].to_s.start_with?("upload-")
      @uploaded_sample = @voice.samples.where(field_recording_speaker_id: nil, removed_at: nil)
        .find_by!(id: FieldVoiceSample.decode_id(params[:id].delete_prefix("upload-")))
      return
    end
    @speaker = kept_speakers.find_by!(id: FieldRecordingSpeaker.decode_id(params[:id]))
  end

  def kept_speakers
    @voice.speakers.joins(:field_recording).merge(FieldRecording.kept)
  end

  def sampled_speaker_ids
    FieldVoiceSample.where(field_voice: @voice, removed_at: nil).where.not(field_recording_speaker_id: nil).select(:field_recording_speaker_id)
  end

  def uploaded_rows
    @voice.samples.where(field_recording_speaker_id: nil, removed_at: nil).order(id: :desc).map do |sample|
      id = "upload-#{sample.to_param}"
      FieldVoiceSamples::Presentation.row(sample).merge(
        id:, source_url: nil, can_relearn: false, has_sample: true,
        contributing: sample.eligible? && sample.profile == @voice.voiceprint&.profile,
        audio_url: (audio_account_field_voice_sample_path(current_account, @voice, id, digest: sample.source_digest) if sample.source_current?),
        error: sample.learning_error
      )
    end
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
      state: sample_state(included:, confirmed:, current:, status:, excluded: speaker.sample_excluded?),
      included:,
      contributing: included && confirmed && sample.profile == @voice.voiceprint&.profile,
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
  # With twenty included, a candidate isn't asked about: it's "spare".
  def sample_state(included:, confirmed:, current:, status:, excluded:)
    return "preparing" if status == "pending"
    return "removed" if excluded
    return "not_ready" unless current
    return "confirmed" if confirmed && included

    full? && !included ? "spare" : "review"
  end

  def full?
    @full = FieldVoiceprints::Limits.full?(@voice) if @full.nil?
    @full
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
