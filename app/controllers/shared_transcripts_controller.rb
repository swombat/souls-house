# The page a transcript link opens (FieldRecordingShare): the recording's
# title, when it was made, and its transcript, with a button to copy it.
# Nothing else of the account is shown: no audio, notes, speakers' voices, or
# who shared it. Anyone with the link may read it, signed in or not.
#
# The link is /shared/transcripts#sht_…: the token is in the fragment, so it
# never reaches a request log here or at any proxy in front (Mira's review of
# #484: path segments are logged whole by Rails::Rack::Logger). `show` sends
# an empty page; the page reads the fragment and POSTs it to `reveal`, where it
# is a `token` parameter, which filter_parameters masks.
class SharedTranscriptsController < ApplicationController

  allow_unauthenticated_access
  before_action :private_headers

  def show
    render inertia: "shared_transcripts/show"
  end

  def reveal
    share = FieldRecordingShare.find_by_token(params[:token])
    unless share&.viewable?
      return render json: { transcript: nil, expired: share.present? && share.expired? }, status: :not_found
    end

    share.record_view!
    recording = share.field_recording
    render json: {
      transcript: {
        title: recording.title,
        recorded_at: (recording.recorded_at || recording.created_at).iso8601,
        duration_ms: recording.duration_ms,
        text: recording.transcript_text.to_s,
        lines: recording.transcript_display_lines,
        expires_at: share.expires_at&.iso8601
      },
      expired: false
    }
  end

  private

  # Keep the page and its answer out of caches and search engines, and send no
  # Referer from it.
  def private_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

end
