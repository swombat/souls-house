# "Look for known voices again" on the transcript page: the two passes that
# ran once when the transcript landed (TranscriptReceiver), run again because
# the Field may know more people since. Each pass keeps its own rules:
#
# - voices (spec 2026-10-19 §8): queued when recognition is on for the
#   account. Matching is in the house and writes under the recording lock, so
#   two presses only match twice. It uses every print that may guess now, and
#   guesses only for speakers no person has decided about;
# - names from what's said (spec §8): queued when that gate is on and no call
#   is claimed right now; reopening the one-call claim is what lets it run
#   again, and it still considers only undecided speakers.
#
# Supplied transcripts have no timed words, so neither pass applies to them.
# Returns the passes queued: [], [:voices], [:names] or both.
module FieldRecording::IdentifyAgain

  module_function

  def queue!(recording)
    return [] unless recording.kept? && recording.ready? && !recording.supplied?

    passes = []
    passes << :voices if queue_voices(recording)
    passes << :names if queue_names(recording)
    passes
  end

  def queue_voices(recording)
    return false unless FieldVoiceprints.enabled_for?(recording.account)

    FieldRecordings::IdentifyJob.perform_later(recording.id)
    true
  end

  def queue_names(recording)
    return false unless FieldSuggestions.enabled?

    reopened = recording.with_lock do
      next false unless recording.kept? && recording.ready? && recording.suggestions_state != "claimed"

      recording.update_columns(suggestions_state: nil)
      true
    end
    FieldRecordings::SuggestSpeakersJob.perform_later(recording.id) if reopened
    reopened
  end

end
