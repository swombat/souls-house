# ElevenLabs posts finished transcriptions here (spec §5). Unauthenticated
# except for the HMAC signature; the attempt token echoed in webhook_metadata
# finds the dispatch, and the lifecycle guards decide whether the result is
# still wanted. Anything signed but unknown is acknowledged and ignored.
class ElevenLabsSttWebhooksController < ApplicationController

  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  def create
    body = request.raw_post
    signed = ElevenLabsScribe.valid_signature?(request.headers["ElevenLabs-Signature"], body,
      secret: ElevenLabsScribe.webhook_secret)
    return head(:unauthorized) unless signed

    event = JSON.parse(body)
    return head(:ok) unless event.is_a?(Hash) && event["type"] == "speech_to_text_transcription"

    data = event["data"].is_a?(Hash) ? event["data"] : {}
    dispatch = dispatch_for(data["webhook_metadata"])
    FieldRecording::TranscriptReceiver.receive!(dispatch, data["transcription"], request_id: data["request_id"]) if dispatch
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def dispatch_for(metadata)
    metadata = JSON.parse(metadata) if metadata.is_a?(String)
    attempt = metadata.is_a?(Hash) ? metadata["attempt"].to_s : ""
    attempt.present? ? FieldRecordingDispatch.find_by(attempt_token: attempt) : nil
  rescue JSON::ParserError
    nil
  end

end
