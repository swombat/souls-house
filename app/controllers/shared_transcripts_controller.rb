# The page a transcript link opens (FieldRecordingShare): the recording's
# title, when it was made, and its transcript as plain lines, with a button to
# copy it. Nothing else of the account is shown: no audio, notes, speakers'
# voices, or who shared it. Anyone with the URL may read it, signed in or not.
class SharedTranscriptsController < ApplicationController

  allow_unauthenticated_access
  before_action :private_headers

  def show
    share = FieldRecordingShare.find_by_token(params[:token])
    unless share&.viewable?
      return render inertia: "shared_transcripts/show",
        props: { transcript: nil, expired: share.present? && share.expired? }, status: :not_found
    end

    share.record_view!
    recording = share.field_recording
    render inertia: "shared_transcripts/show", props: {
      transcript: {
        title: recording.title,
        recorded_at: (recording.recorded_at || recording.created_at).iso8601,
        duration_ms: recording.duration_ms,
        text: recording.transcript_text.to_s,
        expires_at: share.expires_at&.iso8601
      },
      expired: false
    }
  end

  private

  # The token is the whole secret: keep it out of caches, search engines and
  # Referer headers sent to anywhere the page links.
  def private_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

end
