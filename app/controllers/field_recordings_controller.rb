# Recordings in the Field (spec §4–§6). Creating claims a direct upload made
# through FieldRecordingUploadsController; nothing else can be attached.
class FieldRecordingsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_field_recording, only: %i[show update destroy retry correct_line reassign_line resummarize identify_again]

  # The transcript page (spec §7). Words are sent whole: the page renders turns
  # from them, and clicking a word seeks the audio. They are their own prop,
  # `transcript`, with the revision they belong to, so that the page's
  # background refreshes (a reconnect, a speaker named, a summary landing) can
  # reload `recording` without resending them: a long meeting is tens of
  # thousands of words, and on 2026-10-20 a busy server made one open page
  # fetch them again on every reconnect. The page asks for `transcript` itself
  # while the recording's revision differs from the one it holds.
  def show
    recording = @field_recording
    recognition = FieldVoiceprints.enabled_for?(current_account)
    request_playback_copy(recording)
    render inertia: "field/recordings/show", props: {
      recording: -> { FieldItems.recording_json(recording).merge(
        audio_url: player_audio_url(recording),
        turns: (recording.transcript_turns if recording.ready? && recording.supplied?),
        language_code: recording.language_code,
        transcript_revision: (recording.transcript_revision if recording.ready?),
        ready_at: recording.ready_at&.iso8601
      ) },
      transcript: -> {
        recording.ready? ? { revision: recording.transcript_revision, words: recording.transcript_words } : { revision: nil, words: [] }
      },
      # Live links to read the transcript without an account. The URLs
      # themselves aren't here: a link's token is shown once, when it's made.
      shares: -> { recording.shares.active.includes(:created_by).order(created_at: :desc).map(&:as_list_json) },
      speakers: -> { recording.speakers.includes(:field_voice, :recognised_voice).map { |speaker| FieldItems.speaker_json(speaker) } },
      recognition_enabled: recognition,
      voices: -> { FieldItems.voices_json(current_account) },
      members_without_voice: -> { FieldItems.members_without_voice_json(current_account, except: Current.user) },
      my_voice_id: -> { current_account.field_voices.kept.find_by(user: Current.user)&.to_param },
      show_you_hint: -> { show_you_hint?(recording) },
      suggestions_enabled: FieldSuggestions.enabled?,
      account: current_account.as_json
    }
  end

  def create
    attributes = params.require(:field_recording).permit(:upload_id, :title, :note, :expected_speakers, :recorded_at)
    values = attributes.slice(:title, :note, :expected_speakers).to_h.symbolize_keys
    begin
      values[:recorded_at] = FieldDate.parse(attributes[:recorded_at], param: "recorded_at") if attributes[:recorded_at].present?
    rescue FieldDate::Invalid => e
      return redirect_to account_field_path(current_account, tab: "recordings"),
        inertia: { errors: { recorded_at: e.message } }
    end

    recording = FieldRecording::Upload.claim!(
      account: current_account,
      user: Current.user,
      signed_id: attributes[:upload_id],
      attributes: values
    )

    if recording
      FieldRecordings::ProbeJob.perform_later(recording.id)
      redirect_to account_field_path(current_account, tab: "recordings", item: "recording-#{recording.to_param}"),
        notice: "Brought into the Field. Checking the recording…"
    else
      redirect_to account_field_path(current_account, tab: "recordings"),
        inertia: { errors: { audio: "That upload can't be used. Please upload the file again." } }
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_field_path(current_account, tab: "recordings"),
      inertia: { errors: { audio: e.record.errors.full_messages.to_sentence } }
  end

  # From the item viewer (title, note, recorded_at) and the transcript page
  # (notes); each returns to where it was edited. recorded_at, when sent: a
  # date or time to correct when the recording was made, or empty to clear it.
  def update
    submitted = params.require(:field_recording)
    attributes = submitted.permit(:title, :note, :notes)
    if submitted.key?(:recorded_at)
      attributes[:recorded_at] = FieldDate.parse_or_clear(submitted[:recorded_at], param: "recorded_at")
    end

    if @field_recording.update(attributes)
      redirect_back_or_to item_path(@field_recording)
    else
      redirect_back_or_to item_path(@field_recording), alert: @field_recording.errors.full_messages.to_sentence
    end
  rescue FieldDate::Invalid => e
    redirect_to item_path(@field_recording), alert: e.message
  end

  def destroy
    @field_recording.discard_and_settle!
    redirect_to account_field_path(current_account, tab: "recordings"), notice: "Deleted from the Field."
  end

  def retry
    recording = @field_recording.retry!(by: Current.user)
    FieldRecordings::ProbeJob.perform_later(recording.id)
    redirect_to item_path(recording), notice: "Trying again."
  rescue FieldRecording::NotRetryable
    redirect_to item_path(@field_recording), alert: "This recording can't be tried again."
  end

  # "Look for known voices again": the same two passes that ran when the
  # transcript landed, run again now that the Field may know more people
  # (learned voices, or names). Each pass keeps its own rules: only
  # speakers no person has decided anything about are guessed at, a guess is
  # shown for a person to confirm, and each gate is checked as it was then.
  def identify_again
    recording = @field_recording
    passes = FieldRecording::IdentifyAgain.queue!(recording)
    redirect_to account_field_recording_path(current_account, recording), notice: identify_again_notice(passes)
  end

  # One line of the transcript corrected by hand ("Dan", not "Dad").
  # Refusals come back as Inertia errors, so the page keeps the unsaved text.
  def correct_line
    attributes = params.require(:line).permit(:first, :last, :index, :text, :was, :revision)
    @field_recording.correct_line!(
      attributes.slice(:first, :last, :index).to_h.symbolize_keys,
      text: attributes[:text].to_s, was: attributes[:was].to_s, revision: attributes[:revision].to_s
    )
    redirect_to account_field_recording_path(current_account, @field_recording)
  rescue FieldRecording::LineCorrection::Stale
    redirect_to account_field_recording_path(current_account, @field_recording),
      inertia: { errors: { line: "The transcript changed while you were editing. Your text is still here: " \
                                  "copy it, cancel, and open the line again." } }
  rescue FieldRecording::LineCorrection::Invalid => e
    redirect_to account_field_recording_path(current_account, @field_recording), inertia: { errors: { line: e.message } }
  end

  # One line given to another speaker: the transcriber heard Anna as Daniel.
  # `speaker` is a speaker of this recording, or "new" for someone it didn't
  # separate. Refusals come back as Inertia errors, like a text correction.
  def reassign_line
    attributes = params.require(:line).permit(:first, :last, :index, :was, :revision, :speaker)
    to = if attributes[:speaker] == "new"
      :new
    else
      @field_recording.speakers.find_by(id: FieldRecordingSpeaker.decode_id(attributes[:speaker].to_s))
    end
    raise FieldRecording::LineCorrection::Stale unless to

    @field_recording.reassign_line!(
      attributes.slice(:first, :last, :index).to_h.symbolize_keys,
      to:, was: attributes[:was].to_s, revision: attributes[:revision].to_s
    )
    redirect_to account_field_recording_path(current_account, @field_recording)
  rescue FieldRecording::LineCorrection::Stale
    redirect_to account_field_recording_path(current_account, @field_recording),
      inertia: { errors: { line_speaker: "The transcript changed since the page loaded. Please look again." } }
  rescue FieldRecording::LineCorrection::Invalid => e
    redirect_to account_field_recording_path(current_account, @field_recording),
      inertia: { errors: { line_speaker: e.message } }
  end

  # "Is one of these you?" is shown once, until dismissed or answered.
  def dismiss_you_hint
    Current.user.update_column(:field_you_hint_dismissed_at, Time.current)
    head :no_content
  end

  # Write the summary again, e.g. after correcting what it was written from.
  # The page stays where it is; the new summary arrives by refresh.
  def resummarize
    item_path = account_field_path(current_account, tab: "recordings", item: "recording-#{@field_recording.to_param}")
    unless FieldSummaries.enabled?
      return redirect_back_or_to item_path, inertia: { errors: { summary: "Summaries aren't available right now." } }
    end

    if @field_recording.request_resummary!
      redirect_back_or_to item_path
    else
      redirect_back_or_to item_path, inertia: { errors: { summary: "A summary is already being written." } }
    end
  end

  private

  # What the page's player loads: the seekable copy when there is one
  # (FieldRecording::Playback), the original otherwise.
  def player_audio_url(recording)
    return rails_blob_path(recording.playback, disposition: :inline) if recording.playback.attached?

    rails_blob_path(recording.audio, disposition: :inline) if recording.audio.attached?
  end

  # Recordings brought in before the player had copies get one the first
  # time their page is opened. The cache entry keeps a page reloaded ten
  # times from starting ten transcodes; the job itself is harmless twice.
  def request_playback_copy(recording)
    return unless recording.ready? && recording.audio.attached? && !recording.playback.attached?
    return unless recording.audio.blob.content_type == "audio/mpeg"
    return unless Rails.cache.write("field_recording/#{recording.id}/playback", true, unless_exist: true, expires_in: 1.hour)

    FieldRecordings::PlaybackJob.perform_later(recording.id)
  end

  # What "Look for known voices again" can actually do, said up front: the
  # voices pass only compares against prints that passed their held-out check,
  # and a press that quietly finds nothing reads as broken (Daniel, 2026-10-20).
  def identify_again_notice(passes)
    return "Nothing to look for again here." if passes.empty?
    return "Looking again. New guesses appear on the speaker cards for you to confirm." unless passes.include?(:voices)

    names = FieldVoiceprints::Identification.active_prints(current_account).map { |print| print.field_voice.name }.sort
    voices = if names.empty?
      "No voice is checked enough to guess with confidence yet, so anything found is a \"maybe\" hint."
    else
      "Only #{names.to_sentence} #{names.one? ? 'is' : 'are'} checked enough to guess with confidence; other voices this Field knows can show as \"maybe\" hints."
    end
    if names.any? && FieldVoiceprints.auto_naming_for?(current_account)
      voices += " A clear match for one of them names the speaker on its own, marked as named by voice."
    end
    tail = passes.include?(:names) ? " Names from what's said are being looked at too." : ""
    "Looking again. #{voices}#{tail} New guesses appear on the speaker cards for you to confirm. Speakers someone has named keep their names; a guess nobody has confirmed yet can change."
  end

  def set_field_recording
    @field_recording = current_account.field_recordings.kept.find(params[:id])
  end

  def item_path(recording)
    account_field_path(current_account, tab: "recordings", item: "recording-#{recording.to_param}")
  end

  def show_you_hint?(recording)
    recording.ready? && recording.uploaded_by == Current.user && Current.user.field_you_hint_dismissed_at.nil? &&
      !current_account.field_voices.kept.exists?(user: Current.user)
  end

end
