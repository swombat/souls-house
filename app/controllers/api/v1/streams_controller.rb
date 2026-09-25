class Api::V1::StreamsController < Api::V1::BaseController

  before_action :find_readable_stream

  def latest
    now = Time.current
    # Bound by observation time, not arrival order. A late retry cannot become "latest".
    batches = @stream.device_stream_batches
      .where(observed_at: (now - 20.minutes)..(now + 5.minutes))
      .includes(:device_stream_session).order(observed_at: :desc, id: :desc).limit(1201).to_a
    truncated = batches.length > 1200
    batches = batches.first(1200)
    render json: {
      schema: "rr.v1", stream_key: @stream.stream_key, server_time: now.iso8601(6),
      truncated: truncated, window_seconds: 1200,
      latest_received_at: batches.map(&:created_at).max&.iso8601(6),
      batches: batches.reverse.map { |batch|
        { session_id: batch.device_stream_session.session_uuid, sequence: batch.sequence,
          observed_at: batch.observed_at.iso8601(6), received_at: batch.created_at.iso8601(6), rr_ms: batch.rr_ms }
      }
    }
  end

  private

  def find_readable_stream
    response.headers["Cache-Control"] = "no-store"
    @stream = DeviceStream.find_by!(account: current_api_account, stream_key: params[:stream_key])
    raise ActiveRecord::RecordNotFound unless @stream.readable_by?(user: current_api_user, agent: current_api_agent)
  end

end
